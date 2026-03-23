//! snek HTTP server — built on tardy async runtime.
//!
//! Each connection is a stackful coroutine on tardy's per-thread runtime.
//! accept/recv/send yield to the runtime, enabling thousands of concurrent
//! connections per thread with io_uring (Linux) or kqueue (macOS).

const std = @import("std");
const tardy = @import("vendor/tardy/lib.zig");
const posix = std.posix;

const Runtime = tardy.Runtime;
const Socket = tardy.Socket;

const router_mod = @import("http/router.zig");
const http1 = @import("net/http1.zig");
const response_mod = @import("http/response.zig");

pub const HandlerFn = *const fn (*const http1.Parser) response_mod.Response;

/// Python handler invocation — injected at startup, not compiled in.
pub const PyHandlerFn = *const fn (
    py_ctx: ?*anyopaque,
    handler_id: u32,
    parser: *const http1.Parser,
    params: []const router_mod.PathParam,
    buf: []u8,
) response_mod.Response;

pub const Config = struct {
    num_threads: u32 = 0,
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
};

pub const Server = struct {
    router: router_mod.Router,
    handlers: [64]?HandlerFn,
    handler_count: u32,
    py_handler_ids: [64]?u32,
    py_handler_fn: ?PyHandlerFn,
    config: Config,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: Config) Server {
        return .{
            .router = router_mod.Router.init(allocator),
            .handlers = .{null} ** 64,
            .handler_count = 0,
            .py_handler_ids = .{null} ** 64,
            .py_handler_fn = null,
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Server) void {
        self.router.deinit();
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

        const ctx = SetupContext{
            .server = self,
            .listen_socket = listen_socket,
        };

        try t.entry(ctx, setup);
    }

    const SetupContext = struct {
        server: *Server,
        listen_socket: Socket,
    };

    const ClientContext = struct {
        server: *const Server,
        client: Socket,
    };

    fn setup(rt: *Runtime, ctx: SetupContext) !void {
        try rt.spawn(.{ rt, ctx }, acceptLoop, 1024 * 128);
    }

    fn acceptLoop(rt: *Runtime, ctx: SetupContext) !void {
        while (true) {
            const client = ctx.listen_socket.accept(rt) catch continue;
            rt.spawn(.{ rt, ClientContext{ .server = ctx.server, .client = client } }, handleClient, 1024 * 128) catch {
                client.close_blocking();
                continue;
            };
        }
    }

    fn handleClient(rt: *Runtime, ctx: ClientContext) !void {
        defer ctx.client.close_blocking();

        const server = ctx.server;

        // Async recv — tardy coroutine yields here, runtime handles other connections
        var read_buf: [4096]u8 = undefined;
        const n = ctx.client.recv(rt, &read_buf) catch return;
        if (n == 0) return;

        // Parse HTTP
        var parse_buf: [8192]u8 = undefined;
        var parser = http1.Parser.init(&parse_buf);
        _ = parser.feed(read_buf[0..n]) catch {
            const bad = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            _ = ctx.client.send(rt, bad) catch {};
            return;
        };

        const method_str = if (parser.method) |m| @tagName(m) else "GET";
        const method = router_mod.Method.fromString(method_str) orelse .GET;
        const path = parser.uri orelse "/";
        const match_result = server.router.match(method, path);

        // Build response
        var resp_buf: [8192]u8 = undefined;
        const response_bytes: []const u8 = switch (match_result) {
            .found => |found| blk: {
                if (found.handler_id >= server.handler_count) {
                    break :blk "HTTP/1.1 500\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                }

                // Python handler
                if (server.py_handler_ids[found.handler_id]) |py_id| {
                    if (server.py_handler_fn) |handler_fn| {
                        var py_body_buf: [4096]u8 = undefined;
                        var resp = handler_fn(
                            null, // py_ctx — TODO: sub-interpreter support
                            py_id,
                            &parser,
                            found.params[0..found.param_count],
                            &py_body_buf,
                        );
                        _ = resp.setHeader("Connection", "close");
                        const resp_n = resp.serialize(&resp_buf) catch
                            break :blk "HTTP/1.1 500\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                        break :blk resp_buf[0..resp_n];
                    }
                    break :blk "HTTP/1.1 501\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                }

                // Native Zig handler
                if (server.handlers[found.handler_id]) |handler| {
                    var resp = handler(&parser);
                    _ = resp.setHeader("Connection", "close");
                    const resp_n = resp.serialize(&resp_buf) catch
                        break :blk "HTTP/1.1 500\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                    break :blk resp_buf[0..resp_n];
                }

                break :blk "HTTP/1.1 500\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            },
            .not_found => blk: {
                var resp = response_mod.Response.notFound();
                _ = resp.setHeader("Connection", "close");
                const resp_n = resp.serialize(&resp_buf) catch
                    break :blk "HTTP/1.1 404\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                break :blk resp_buf[0..resp_n];
            },
            .method_not_allowed => "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        };

        // Async send — yields to runtime
        _ = ctx.client.send(rt, response_bytes) catch {};
    }
};
