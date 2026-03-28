//! snek HTTP server — stackless runtime with own AIO layer.
//!
//! Each worker thread owns a sub-interpreter with its own GIL (PEP 734).
//! No cross-thread GIL contention.

const std = @import("std");
const Socket = @import("socket.zig").Socket;
const Runtime = @import("runtime.zig").Runtime;
const Task = @import("task.zig").Task;
const acceptor = @import("acceptor.zig");
const conn_mod = @import("connection.zig");
const handler = @import("handler.zig");
const subinterp = @import("python/subinterp.zig");
const router_mod = @import("http/router.zig");
const Pool = @import("pool.zig").Pool;
const RedisReader = @import("redis/reader.zig").RedisReader;
const redis_async = @import("redis/async.zig");

const log = std.log.scoped(.@"snek/server");

pub const HandlerFn = handler.HandlerFn;

// ── Route table ─────────────────────────────────────────────────────

pub const Server = struct {
    router: router_mod.Router,
    handlers: [64]?HandlerFn,
    handler_count: u32,
    py_handler_ids: [64]?u32,
    host: []const u8,
    port: u16,
    num_threads: usize,
    module_ref: [256]u8,
    module_ref_len: u16,

    pub fn init(alloc: std.mem.Allocator, host: []const u8, port: u16) Server {
        return .{
            .router = router_mod.Router.init(alloc),
            .handlers = .{null} ** 64,
            .handler_count = 0,
            .py_handler_ids = .{null} ** 64,
            .host = host,
            .port = port,
            .num_threads = 1,
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
        self.handler_count = id + 1;
        try self.router.addRoute(method, path, id);
    }

    pub fn addPythonRoute(self: *Server, method: router_mod.Method, path: []const u8, py_handler_id: u32) !void {
        const id = self.handler_count;
        if (id >= 64) return error.TooManyHandlers;
        self.handlers[id] = null;
        self.py_handler_ids[id] = py_handler_id;
        self.handler_count = id + 1;
        try self.router.addRoute(method, path, id);
    }
};

// ── Per-thread state ────────────────────────────────────────────────

pub const ThreadContext = struct {
    py: subinterp.WorkerPyContext,
};

threadlocal var tl_ctx: ?ThreadContext = null;
threadlocal var tl_req_ctx: ?handler.RequestContext = null;
threadlocal var tl_py: ?subinterp.WorkerPyContext = null;
threadlocal var tl_py_ctx: ?handler.PyContext = null;
threadlocal var tl_redis_reader: ?*RedisReader = null;
threadlocal var tl_redis_ctx_pool: ?*Pool(redis_async.RedisCtx) = null;

/// Sub-interpreter creation must be serialized — PyGILState_Ensure is not
/// thread-safe when called from threads without a Python thread state.
var interp_mutex: std.Thread.Mutex = .{};

pub fn getThreadContext() ?*ThreadContext {
    return if (tl_ctx) |*ctx| ctx else null;
}

pub fn getRequestContext() ?*const handler.RequestContext {
    return if (tl_req_ctx) |*ctx| ctx else null;
}

pub fn getRedisReader() ?*RedisReader {
    return tl_redis_reader;
}

pub fn getRedisCtxPool() ?*Pool(redis_async.RedisCtx) {
    return tl_redis_ctx_pool;
}

// ── Runtime ─────────────────────────────────────────────────────────

pub fn run(allocator: std.mem.Allocator, server: *const Server) !void {
    const num_threads: usize = 1;
    log.info("starting with {d} threads on {s}:{d}", .{ num_threads, server.host, server.port });

    var threads: std.ArrayListUnmanaged(std.Thread) = .{};
    defer threads.deinit(allocator);

    for (1..num_threads) |_| {
        const t = try std.Thread.spawn(.{}, threadMain, .{ allocator, server });
        try threads.append(allocator, t);
    }

    try threadMain(allocator, server);

    for (threads.items) |t| t.join();
}

fn threadMain(allocator: std.mem.Allocator, server: *const Server) !void {
    log.debug("worker thread setup", .{});

    const listen_socket = try Socket.initTcp(server.host, server.port);
    try listen_socket.bind();
    try listen_socket.listen(128);

    // Set up sub-interpreter for this thread
    if (server.module_ref_len > 0) {
        interp_mutex.lock();
        defer interp_mutex.unlock();
        const ref = server.module_ref[0..server.module_ref_len];
        log.debug("creating sub-interpreter", .{});
        tl_py = try subinterp.WorkerPyContext.init(ref);
        tl_py_ctx = .{ .py = &tl_py.? };
        tl_ctx = .{ .py = tl_py.? };
        log.debug("sub-interpreter ready", .{});
    }

    tl_req_ctx = .{
        .router = &server.router,
        .handlers = &server.handlers,
        .py_handler_ids = &server.py_handler_ids,
        .py_ctx = if (tl_py_ctx) |*p| p else null,
    };

    var rt = try Runtime.init(allocator, 1024);
    defer rt.deinit(allocator);

    // Separate pools for Tasks, ConnCtx, and RedisCtx
    var tasks = try Pool(Task).init(allocator, 1024, .static);
    defer tasks.deinit();

    var connections = try Pool(conn_mod.ConnCtx).init(allocator, 1024, .static);
    defer connections.deinit();

    // Redis context pool
    var redis_ctxs = try Pool(redis_async.RedisCtx).init(allocator, 1024, .static);
    defer redis_ctxs.deinit();
    tl_redis_ctx_pool = &redis_ctxs;

    // Redis reader — single pipelined connection
    var redis_reader_storage: RedisReader = undefined;
    if (tl_py) |*py_ctx| {
        const redis_host = std.posix.getenv("REDIS_HOST") orelse "127.0.0.1";
        const redis_fd = RedisReader.connectTcp(redis_host, 6379) catch |err| blk: {
            log.info("redis not available at {s}: {}, redis commands will fail", .{ redis_host, err });
            break :blk null;
        };
        if (redis_fd) |fd| {
            redis_reader_storage = try RedisReader.init(allocator, fd, &rt, py_ctx);
            redis_reader_storage.initTask();
            tl_redis_reader = &redis_reader_storage;
            log.info("redis reader connected fd={d}", .{fd});
        }
    }

    // Acceptor context + task (long-lived, not pooled)
    var accept_ctx = acceptor.AcceptCtx{
        .listen_fd = listen_socket.handle,
        .rt = &rt,
        .connections = &connections,
        .tasks = &tasks,
        .allocator = allocator,
    };
    var accept_task = Task.init(acceptor.AcceptCtx, &accept_ctx, acceptor.onAccept);
    try rt.queue(&accept_task, IoOp{ .accept = .{ .socket = listen_socket.handle } });

    log.debug("event loop starting", .{});
    try rt.run();
}

const IoOp = @import("aio/io_op.zig").IoOp;
const pipeline_mod = @import("pipeline.zig");

// ── Pipeline runtime (staged, no step functions) ──────────────────

pub fn runPipeline(allocator: std.mem.Allocator, server: *const Server) !void {
    const num_threads = server.num_threads;
    log.info("pipeline: starting {d} threads on {s}:{d}", .{ num_threads, server.host, server.port });

    var threads: std.ArrayListUnmanaged(std.Thread) = .{};
    defer threads.deinit(allocator);

    for (1..num_threads) |_| {
        const t = try std.Thread.spawn(.{}, pipelineThreadMain, .{ allocator, server });
        try threads.append(allocator, t);
    }

    try pipelineThreadMain(allocator, server);

    for (threads.items) |t| t.join();
}

fn pipelineThreadMain(allocator: std.mem.Allocator, server: *const Server) !void {
    // Each thread gets its own socket (SO_REUSEPORT distributes connections)
    const listen_socket = try Socket.initTcp(server.host, server.port);
    try listen_socket.bind();
    try listen_socket.listen(128);

    // Each thread gets its own sub-interpreter with its own GIL (PEP 734)
    if (server.module_ref_len > 0) {
        interp_mutex.lock();
        defer interp_mutex.unlock();
        const ref = server.module_ref[0..server.module_ref_len];
        tl_py = try subinterp.WorkerPyContext.init(ref);
        tl_py.?.acquireGil();
        const driver = @import("python/driver.zig");
        try driver.initStringCache();
        tl_py.?.releaseGil();
        tl_py_ctx = .{ .py = &tl_py.? };
        tl_ctx = .{ .py = tl_py.? };
    }

    tl_req_ctx = .{
        .router = &server.router,
        .handlers = &server.handlers,
        .py_handler_ids = &server.py_handler_ids,
        .py_ctx = if (tl_py_ctx) |*p| p else null,
    };

    // Each thread gets its own pipeline + conn pool + io backend
    var conns = try Pool(pipeline_mod.Conn).init(allocator, 1024, .static);
    defer conns.deinit();

    const pl = try allocator.create(pipeline_mod.Pipeline);
    defer allocator.destroy(pl);
    pl.* = try pipeline_mod.Pipeline.init(allocator, &conns, 1024);

    pl.req_ctx = if (tl_req_ctx) |*ctx| ctx else null;

    // Redis connection (optional, one pipelined connection per thread)
    if (tl_py != null) {
        const redis_host = std.posix.getenv("REDIS_HOST") orelse "127.0.0.1";
        const redis_fd = RedisReader.connectTcp(redis_host, 6379) catch |err| blk: {
            log.info("redis not available at {s}: {}, redis commands will fail", .{ redis_host, err });
            break :blk null;
        };
        if (redis_fd) |fd| {
            pl.initRedis(fd);
        }
    }

    try pl.start(listen_socket.handle);
    log.info("pipeline: thread ready", .{});

    try pl.run();
}
