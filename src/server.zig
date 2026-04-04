//! snek HTTP server — stackless runtime with own AIO layer.
//!
//! Each worker thread owns a sub-interpreter with its own GIL (PEP 734).
//! No cross-thread GIL contention.

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const Socket = @import("socket.zig").Socket;
const handler = @import("handler.zig");
const ffi = @import("python/ffi.zig");
const subinterp = @import("python/subinterp.zig");
const py_module = @import("python/module.zig");
const router_mod = @import("http/router.zig");
const Pool = @import("pool.zig").Pool;

const log = std.log.scoped(.@"snek/server");

pub const HandlerFn = handler.HandlerFn;

// ── Route table ─────────────────────────────────────────────────────

pub const Server = struct {
    router: router_mod.Router,
    handlers: [64]?HandlerFn,
    handler_count: u32,
    py_handler_ids: [64]?u32,
    py_handler_flags: [64]handler.PyHandlerFlags,
    host: []const u8,
    port: u16,
    num_threads: usize,
    backlog: u31,
    module_ref: [256]u8,
    module_ref_len: u16,

    pub fn init(alloc: std.mem.Allocator, host: []const u8, port: u16) Server {
        return .{
            .router = router_mod.Router.init(alloc),
            .handlers = .{null} ** 64,
            .handler_count = 0,
            .py_handler_ids = .{null} ** 64,
            .py_handler_flags = .{handler.PyHandlerFlags{}} ** 64,
            .host = host,
            .port = port,
            .num_threads = 1,
            .backlog = 2048,
            .module_ref = .{0} ** 256,
            .module_ref_len = 0,
        };
    }

    pub fn deinit(self: *Server) void {
        self.router.deinit();
    }

    pub fn setModuleRef(self: *Server, ref: []const u8) void {
        if (ref.len > 0 and ref.len < self.module_ref.len) {
            @memcpy(self.module_ref[0..ref.len], ref);
            self.module_ref_len = @intCast(ref.len);
        }
    }

    pub fn addRoute(self: *Server, method: router_mod.Method, path: []const u8, h: HandlerFn) !void {
        const id = self.handler_count;
        if (id >= 64) return error.TooManyHandlers;
        self.handlers[id] = h;
        self.py_handler_ids[id] = null;
        self.py_handler_flags[id] = .{};
        self.handler_count = id + 1;
        try self.router.addRoute(method, path, id);
    }

    pub fn addPythonRoute(self: *Server, method: router_mod.Method, path: []const u8, py_handler_id: u32) !void {
        const id = self.handler_count;
        if (id >= 64) return error.TooManyHandlers;
        self.handlers[id] = null;
        self.py_handler_ids[id] = py_handler_id;
        self.py_handler_flags[id] = .{};
        self.handler_count = id + 1;
        try self.router.addRoute(method, path, id);
    }
};

/// Sub-interpreter creation must be serialized — PyGILState_Ensure is not
/// thread-safe when called from threads without a Python thread state.
var interp_mutex: std.Thread.Mutex = .{};

const pipeline_mod = switch (builtin.os.tag) {
    .linux => @import("uring/pipeline.zig"),
    else => @import("pipeline_kq.zig"),
};

// ── Active Server Runtime ──────────────────────────────────────────

pub fn run(allocator: std.mem.Allocator, server: *const Server) !void {
    const num_threads = server.num_threads;

    // Bind the first socket without SO_REUSEPORT.
    // If the port is already in use, bind fails naturally with AddressInUse.
    const first_socket = try Socket.initTcp(server.host, server.port);
    first_socket.bind() catch |err| switch (err) {
        error.AddressInUse => {
            log.err("port {d} is already in use — kill the existing process first", .{server.port});
            return error.PortAlreadyInUse;
        },
        else => return err,
    };
    if (num_threads > 1) try first_socket.enableReusePort();
    try first_socket.listen(server.backlog);

    log.info("pipeline: starting {d} threads on {s}:{d}", .{ num_threads, server.host, server.port });

    var threads: std.ArrayListUnmanaged(std.Thread) = .{};
    defer threads.deinit(allocator);

    for (1..num_threads) |i| {
        const t = try std.Thread.spawn(.{}, pipelineThreadMain, .{ allocator, server, @as(?Socket, null), @as(u16, @intCast(i)) });
        try threads.append(allocator, t);
    }

    try pipelineThreadMain(allocator, server, first_socket, 0);

    for (threads.items) |t| t.join();
}

fn pipelineThreadMain(allocator: std.mem.Allocator, server: *const Server, existing_socket: ?Socket, thread_idx: u16) !void {
    // Pin thread to CPU core (Linux only) — prevents cache thrashing from migration
    if (comptime @import("builtin").os.tag == .linux) {
        var set: std.os.linux.cpu_set_t = .{0} ** @typeInfo(std.os.linux.cpu_set_t).array.len;
        const word_idx = thread_idx / @bitSizeOf(usize);
        set[word_idx] = @as(usize, 1) << @intCast(thread_idx % @bitSizeOf(usize));
        std.os.linux.sched_setaffinity(0, &set) catch |err| {
            log.info("core affinity failed for thread {d}: {}", .{ thread_idx, err });
        };
    }
    const listen_socket = if (existing_socket) |s| s else blk: {
        // Additional threads create their own socket with SO_REUSEPORT
        const s = try Socket.initTcp(server.host, server.port);
        try s.enableReusePort();
        try s.bind();
        try s.listen(server.backlog);
        break :blk s;
    };

    var worker_py: ?subinterp.WorkerPyContext = null;
    var worker_py_ctx: ?handler.PyContext = null;

    // Each thread gets its own sub-interpreter with its own GIL (PEP 734)
    if (server.module_ref_len > 0) {
        interp_mutex.lock();
        defer interp_mutex.unlock();
        const ref = server.module_ref[0..server.module_ref_len];
        worker_py = try subinterp.WorkerPyContext.init(ref);
        worker_py.?.acquireGil();
        const snek_row = @import("python/snek_row.zig");
        const snek_request = @import("python/snek_request.zig");
        try snek_row.initType();
        try snek_request.initType();
        worker_py.?.releaseGil();
        worker_py_ctx = .{ .py = &worker_py.? };
    }

    defer {
        if (worker_py) |*py| {
            py.deinit();
        }
    }

    var worker_py_handler_flags = server.py_handler_flags;
    if (worker_py) |*py| {
        refreshWorkerPyHandlerFlags(server, py.snek_module, &worker_py_handler_flags);
    }

    var req_ctx: handler.RequestContext = .{
        .router = &server.router,
        .handlers = &server.handlers,
        .py_handler_ids = &server.py_handler_ids,
        .py_handler_flags = &worker_py_handler_flags,
        .py_ctx = if (worker_py_ctx) |*p| p else null,
    };

    // Each thread gets its own pipeline + conn pool + io backend
    var conns = try Pool(pipeline_mod.Conn).init(allocator, 1024, .static);
    defer conns.deinit();

    const pl = try allocator.create(pipeline_mod.Pipeline);
    defer allocator.destroy(pl);
    try pl.init(allocator, &conns, 1024);

    pl.req_ctx = &req_ctx;

    // Redis connection (optional, one pipelined connection per thread)
    if (worker_py != null) {
        const redis_host = std.posix.getenv("REDIS_HOST") orelse "127.0.0.1";
        const redis_fd = connectTcpNonBlocking(redis_host, 6379) catch |err| blk: {
            log.info("redis not available at {s}: {}, redis commands will fail", .{ redis_host, err });
            break :blk null;
        };
        if (redis_fd) |fd| {
            pl.initRedis(fd);
        }
    }

    // Postgres connection pool (optional, N pipelined connections per thread)
    if (worker_py != null) {
        const pg_host = posix.getenv("PG_HOST") orelse "127.0.0.1";
        const pg_port_str = posix.getenv("PG_PORT") orelse "5432";
        const pg_port = std.fmt.parseInt(u16, pg_port_str, 10) catch 5432;
        const pg_user = posix.getenv("PG_USER") orelse "postgres";
        const pg_pass = posix.getenv("PG_PASS") orelse "";
        const pg_db = posix.getenv("PG_DB") orelse "postgres";
        const pg_pool_str = posix.getenv("PG_POOL_SIZE") orelse "1";
        const pg_pool_size = std.fmt.parseInt(u8, pg_pool_str, 10) catch 1;
        const query_mod = @import("db/query.zig");
        for (0..pg_pool_size) |_| {
            const pg_client = query_mod.Client.connect(allocator, pg_host, pg_port, pg_user, pg_db, pg_pass) catch |err| {
                log.info("postgres not available at {s}:{d}: {}, stopping pool init", .{ pg_host, pg_port, err });
                break;
            };
            pl.addPgConn(pg_client.fd) catch break;
        }
    }

    try pl.start(listen_socket.handle);
    log.info("pipeline: thread ready", .{});

    try pl.run();
}

fn refreshWorkerPyHandlerFlags(server: *const Server, mod: *ffi.PyObject, dst: *[64]handler.PyHandlerFlags) void {
    for (0..server.handler_count) |idx| {
        if (server.py_handler_ids[idx]) |py_id| {
            const flags = py_module.getHandlerFlags(mod, py_id);
            dst[idx] = .{
                .needs_request = flags.needs_request,
                .needs_params = flags.needs_params,
                .no_args = flags.no_args,
                .is_async = flags.is_async,
            };
        }
    }
}

fn connectTcpNonBlocking(host: []const u8, port: u16) !std.posix.socket_t {
    const addr = std.net.Address.resolveIp(host, port) catch blk: {
        const list = try std.net.getAddressList(std.heap.page_allocator, host, port);
        defer list.deinit();
        if (list.addrs.len == 0) return error.NameResolutionFailed;
        break :blk list.addrs[0];
    };
    const fd = try std.posix.socket(addr.any.family, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK, std.posix.IPPROTO.TCP);
    errdefer std.posix.close(fd);
    std.posix.connect(fd, &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock => {},
        else => return err,
    };
    return fd;
}
