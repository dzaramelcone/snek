//! snek HTTP server — built on tardy async runtime.
//!
//! Each tardy thread owns a sub-interpreter with its own GIL (PEP 734).
//! No cross-thread GIL contention.

const std = @import("std");
const tardy = @import("vendor/tardy/lib.zig");

const Runtime = tardy.Runtime;
const Socket = tardy.Socket;

const router_mod = @import("http/router.zig");
const http1 = @import("net/http1.zig");
const response_mod = @import("http/response.zig");
const subinterp = @import("python/subinterp.zig");
const driver = @import("python/driver.zig");
const redis = @import("redis/connection.zig");

pub const HandlerFn = *const fn (*const http1.Request) response_mod.Response;

pub const Config = struct {
    num_threads: u32 = 0,
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
};

/// Per-thread state: sub-interpreter + optional redis connection.
/// Stored in thread-local, accessible from handler invocations.
pub const ThreadContext = struct {
    py: subinterp.WorkerPyContext,
    redis_client: ?redis.Client = null,
    rt: *Runtime = undefined,
};

threadlocal var tl_ctx: ?ThreadContext = null;

/// Get this thread's context. Called by Python-facing redis functions.
pub fn getThreadContext() ?*ThreadContext {
    return if (tl_ctx) |*ctx| ctx else null;
}

pub const Server = struct {
    router: router_mod.Router,
    handlers: [64]?HandlerFn,
    handler_count: u32,
    py_handler_ids: [64]?u32,
    config: Config,
    allocator: std.mem.Allocator,
    module_ref: [256]u8,
    module_ref_len: u16,

    pub fn init(allocator: std.mem.Allocator, config: Config) Server {
        return .{
            .router = router_mod.Router.init(allocator),
            .handlers = .{null} ** 64,
            .handler_count = 0,
            .py_handler_ids = .{null} ** 64,
            .config = config,
            .allocator = allocator,
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

    pub fn addRoute(self: *Server, method: router_mod.Method, path: []const u8, handler: HandlerFn) !void {
        const id = self.handler_count;
        if (id >= 64) return error.TooManyHandlers;
        self.handlers[id] = handler;
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

    pub fn run(self: *Server) !void {
        const addr = std.net.Address.parseIp4(self.config.host, self.config.port) catch unreachable;
        const listen_socket = try Socket.init_with_address(.tcp, addr);
        try listen_socket.bind();
        try listen_socket.listen(128);

        const num_threads = if (self.config.num_threads == 0)
            @as(u32, @intCast(@max(1, std.Thread.getCpuCount() catch 1)))
        else
            self.config.num_threads;

        const TardyImpl = tardy.Tardy(tardy.auto_async_match());
        var t = try TardyImpl.init(self.allocator, .{
            .threading = .{ .multi = @intCast(num_threads) },
        });
        defer t.deinit();

        try t.entry(SetupContext{ .server = self, .listen_socket = listen_socket }, setup);
    }

    const SetupContext = struct {
        server: *Server,
        listen_socket: Socket,
    };

    const ClientContext = struct {
        server: *const Server,
        client: Socket,
        rt: *Runtime,
    };

    fn setup(rt: *Runtime, ctx: SetupContext) !void {
        if (ctx.server.module_ref_len > 0) {
            tl_ctx = .{
                .py = try subinterp.WorkerPyContext.init(
                    ctx.server.module_ref[0..ctx.server.module_ref_len],
                ),
                .rt = rt,
            };
        }
        try rt.spawn(.{ rt, ctx }, acceptLoop, 1024 * 128);
    }

    fn acceptLoop(rt: *Runtime, ctx: SetupContext) !void {
        while (true) {
            const client = ctx.listen_socket.accept(rt) catch continue;
            rt.spawn(.{ rt, ClientContext{ .server = ctx.server, .client = client, .rt = rt } }, handleClient, 1024 * 128) catch {
                client.close_blocking();
                continue;
            };
        }
    }

    fn handleClient(rt: *Runtime, ctx: ClientContext) !void {
        defer ctx.client.close_blocking();

        var read_buf: [4096]u8 = undefined;
        const n = try ctx.client.recv(rt, &read_buf);
        if (n == 0) return;

        var resp_buf: [8192]u8 = undefined;
        const bytes = serveRequest(rt, ctx.server, read_buf[0..n], &resp_buf) catch |err|
            errorResponse(err);

        _ = try ctx.client.send(rt, bytes);
    }

    fn serveRequest(rt: *Runtime, server: *const Server, raw: []const u8, resp_buf: []u8) ![]const u8 {
        const req = try http1.Request.parse(raw);

        const method_str = if (req.method) |m| @tagName(m) else "GET";
        const method = router_mod.Method.fromString(method_str) orelse .GET;
        const path = req.uri orelse "/";

        var resp = switch (server.router.match(method, path)) {
            .found => |found| blk: {
                if (server.py_handler_ids[found.handler_id]) |py_id| {
                    if (tl_ctx) |*ctx| {
                        // Set rt for this request so redis calls can yield
                        ctx.rt = rt;
                        var py_body_buf: [4096]u8 = undefined;
                        break :blk driver.invokePythonHandler(
                            ctx.py.snek_module, py_id, &req,
                            found.params[0..found.param_count], &py_body_buf,
                        );
                    }
                    return "HTTP/1.1 503\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                }
                if (server.handlers[found.handler_id]) |handler|
                    break :blk handler(&req);
                return "HTTP/1.1 500\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            },
            .not_found => response_mod.Response.notFound(),
            .method_not_allowed => return "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        };
        _ = resp.setHeader("Connection", "close");
        return resp_buf[0..try resp.serialize(resp_buf)];
    }

    fn errorResponse(err: anyerror) []const u8 {
        return switch (err) {
            error.MalformedRequest, error.BadMethod, error.BadVersion,
            error.UriTooLong, error.BadHeaderLine, error.TooManyHeaders,
            error.HeaderTooLarge, error.BufferFull,
            => "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            else => "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        };
    }
};
