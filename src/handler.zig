//! Shared request handler: route matching, Python invocation, response serialization.
//!
//! Used by the active staged server pipelines.
//! Takes a parsed http1.Request, returns serialized response bytes.

const std = @import("std");
const http1 = @import("net/http1.zig");
const router_mod = @import("http/router.zig");
const response_mod = @import("http/response.zig");
const driver = @import("python/driver.zig");
const subinterp = @import("python/subinterp.zig");
const response_hint_mod = @import("response_hint.zig");

const log = std.log.scoped(.@"snek/handler");

pub const HandlerFn = *const fn (*const http1.Request) response_mod.Response;

pub const PyHandlerFlags = extern struct {
    needs_request: bool = true,
    needs_params: bool = false,
    no_args: bool = false,
    is_async: bool = false,
    response_hint: u8 = @intFromEnum(response_hint_mod.ResponseHint.any),
};

/// Everything needed to handle a request. Shared across server implementations.
pub const RequestContext = struct {
    router: *const router_mod.Router,
    handlers: *const [64]?HandlerFn,
    py_handler_ids: *const [64]?u32,
    py_handler_flags: ?*const [64]PyHandlerFlags = null,
    py_ctx: ?*PyContext = null,
};

/// Per-thread Python context for handler invocations.
pub const PyContext = struct {
    py: *subinterp.WorkerPyContext,
};

/// Result of handling a request — either response bytes or async I/O needed.
pub const HandleResult = union(enum) {
    /// Response is ready — slice into resp_buf.
    response: []const u8,
    /// Python coroutine needs async redis I/O.
    redis_yield: driver.InvokeResult.redis_yield_type(),
};

/// Result for pipeline — Response object (not serialized) or redis yield.
pub const RawResult = union(enum) {
    response: response_mod.Response,
    redis_yield: driver.InvokeResult.redis_yield_type(),
};

/// Handle request, return structured Response (not serialized).
/// body_buf is where Python response body text is copied into.
pub fn handleRequestRaw(
    req: *const http1.Request,
    ctx: *const RequestContext,
    body_buf: []u8,
) RawResult {
    const method_str = if (req.method) |m| @tagName(m) else "GET";
    const method = router_mod.Method.fromString(method_str) orelse .GET;
    const path = req.uri orelse "/";

    switch (ctx.router.match(method, path)) {
        .found => |found| {
            if (ctx.py_handler_ids[found.handler_id]) |py_id| {
                if (ctx.py_ctx) |py| {
                    py.py.acquireGil();
                    const invoke_result = driver.invokePythonHandler(
                        py.py.snek_module,
                        py_id,
                        req,
                        found.params[0..found.param_count],
                        body_buf,
                        null,
                        null,
                        null,
                        null,
                        null,
                        null,
                    );
                    switch (invoke_result) {
                        .response => |owned| {
                            py.py.releaseGil();
                            var py_resp = owned;
                            defer py_resp.deinit();
                            return .{ .response = py_resp.response };
                        },
                        .redis_yield => |ry| {
                            py.py.releaseGil();
                            return .{ .redis_yield = ry };
                        },
                    }
                }
                return .{ .response = response_mod.Response.init(503) };
            }
            if (ctx.handlers[found.handler_id]) |handler| {
                return .{ .response = handler(req) };
            }
            return .{ .response = response_mod.Response.init(500) };
        },
        .not_found => return .{ .response = response_mod.Response.notFound() },
        .method_not_allowed => {
            var r = response_mod.Response.init(405);
            r.body = "Method Not Allowed";
            return .{ .response = r };
        },
    }
}

/// Handle a parsed HTTP request: route, invoke handler, serialize response.
/// Returns HandleResult — either response bytes or async redis yield.
pub fn handleRequest(
    req: *const http1.Request,
    ctx: *const RequestContext,
    resp_buf: []u8,
) HandleResult {
    const method_str = if (req.method) |m| @tagName(m) else "GET";
    const method = router_mod.Method.fromString(method_str) orelse .GET;
    const path = req.uri orelse "/";

    log.debug("routing {s} {s}", .{ method_str, path });

    switch (ctx.router.match(method, path)) {
        .found => |found| {
            log.debug("route matched handler_id={d} params={d}", .{ found.handler_id, found.param_count });

            if (ctx.py_handler_ids[found.handler_id]) |py_id| {
                if (ctx.py_ctx) |py| {
                    log.debug("invoking python handler py_id={d}", .{py_id});
                    var py_body_buf: [4096]u8 = undefined;
                    py.py.acquireGil();
                    const invoke_result = driver.invokePythonHandler(
                        py.py.snek_module,
                        py_id,
                        req,
                        found.params[0..found.param_count],
                        &py_body_buf,
                        null,
                        null,
                        null,
                        null,
                        null,
                        null,
                    );

                    switch (invoke_result) {
                        .response => |owned| {
                            py.py.releaseGil();
                            var py_resp = owned;
                            defer py_resp.deinit();
                            log.debug("python handler returned status={d}", .{py_resp.response.status});
                            var resp = py_resp.response;
                            const len = resp.serialize(resp_buf) catch {
                                log.err("response serialization failed", .{});
                                return .{ .response = "HTTP/1.1 500\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" };
                            };
                            return .{ .response = resp_buf[0..len] };
                        },
                        .redis_yield => |ry| {
                            py.py.releaseGil();
                            log.debug("python handler yielded redis sentinel", .{});
                            return .{ .redis_yield = ry };
                        },
                    }
                }
                log.warn("no python context for handler py_id={d}", .{py_id});
                return .{ .response = "HTTP/1.1 503\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" };
            }
            if (ctx.handlers[found.handler_id]) |handler| {
                log.debug("invoking native handler", .{});
                var resp = handler(req);
                const len = resp.serialize(resp_buf) catch {
                    log.err("response serialization failed", .{});
                    return .{ .response = "HTTP/1.1 500\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" };
                };
                return .{ .response = resp_buf[0..len] };
            }
            log.warn("no handler for matched route", .{});
            return .{ .response = "HTTP/1.1 500\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" };
        },
        .not_found => {
            log.debug("route not found", .{});
            var resp = response_mod.Response.notFound();
            const len = resp.serialize(resp_buf) catch {
                return .{ .response = "HTTP/1.1 404\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" };
            };
            return .{ .response = resp_buf[0..len] };
        },
        .method_not_allowed => {
            log.debug("method not allowed", .{});
            return .{ .response = "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" };
        },
    }
}

/// Map a parse/request error to an error response.
pub fn errorResponse(err: anyerror) []const u8 {
    log.debug("error response for {}", .{err});
    return switch (err) {
        error.MalformedRequest,
        error.BadMethod,
        error.BadVersion,
        error.UriTooLong,
        error.BadHeaderLine,
        error.TooManyHeaders,
        error.HeaderTooLarge,
        error.BufferFull,
        => "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        else => "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    };
}
