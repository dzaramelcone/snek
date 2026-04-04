//! Higher-level HTTP response builder with fluent API.
//!
//! SEPARATE from net/http1.zig's Response — that one is a low-level serializer,
//! this one is the user-facing API with convenience constructors.
//! Self-contained: inlines serialization so it can be tested standalone.

const std = @import("std");
const http = std.http;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

const MAX_HEADERS: usize = 32;

pub const Response = struct {
    status: http.Status,
    headers: [MAX_HEADERS]Header,
    header_count: usize,
    body: ?[]const u8,

    pub fn init(status: http.Status) Response {
        return .{
            .status = status,
            .headers = undefined,
            .header_count = 0,
            .body = null,
        };
    }

    /// Set a header (fluent).
    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) *Response {
        if (self.header_count < MAX_HEADERS) {
            self.headers[self.header_count] = .{ .name = name, .value = value };
            self.header_count += 1;
        }
        return self;
    }

    /// Set the response body (fluent).
    pub fn setBody(self: *Response, b: []const u8) *Response {
        self.body = b;
        return self;
    }

    /// Set Content-Type header (fluent).
    pub fn setContentType(self: *Response, ct: []const u8) *Response {
        return self.setHeader("Content-Type", ct);
    }

    /// 200 + application/json
    pub fn json(b: []const u8) Response {
        var r = init(.ok);
        _ = r.setContentType("application/json");
        r.body = b;
        return r;
    }

    /// 200 + text/plain
    pub fn text(b: []const u8) Response {
        var r = init(.ok);
        _ = r.setContentType("text/plain");
        r.body = b;
        return r;
    }

    /// 200 + text/html
    pub fn html(b: []const u8) Response {
        var r = init(.ok);
        _ = r.setContentType("text/html");
        r.body = b;
        return r;
    }

    /// 302 + Location header
    pub fn redirect(location: []const u8) Response {
        var r = init(.found);
        _ = r.setHeader("Location", location);
        return r;
    }

    /// 404 Not Found
    pub fn notFound() Response {
        var r = init(.not_found);
        r.body = "Not Found";
        return r;
    }

    /// 405 + Allow header
    pub fn methodNotAllowed(allowed: []const u8) Response {
        var r = init(.method_not_allowed);
        _ = r.setHeader("Allow", allowed);
        r.body = "Method Not Allowed";
        return r;
    }

    /// Serialize to HTTP/1.1 response bytes.
    /// Mirrors zzz's response writer: status line, Connection: keep-alive,
    /// user headers, Content-Length, blank line, body.
    pub fn serialize(self: *const Response, buf: []u8) error{ BufferTooSmall, UnsupportedStatus }!usize {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();

        // Status line
        w.writeAll(try statusLine(self.status)) catch return error.BufferTooSmall;

        // Connection: keep-alive (matches zzz behavior)
        w.writeAll("Connection: keep-alive\r\n") catch return error.BufferTooSmall;

        // User headers
        for (self.headers[0..self.header_count]) |h| {
            w.print("{s}: {s}\r\n", .{ h.name, h.value }) catch return error.BufferTooSmall;
        }

        // Content-Length
        if (self.body) |b| {
            w.print("Content-Length: {d}\r\n", .{b.len}) catch return error.BufferTooSmall;
        }

        // End of headers
        w.writeAll("\r\n") catch return error.BufferTooSmall;

        // Body
        if (self.body) |b| {
            w.writeAll(b) catch return error.BufferTooSmall;
        }

        return fbs.pos;
    }
};

fn statusLine(status: http.Status) error{UnsupportedStatus}![]const u8 {
    return switch (status) {
        .ok => "HTTP/1.1 200 OK\r\n",
        .created => "HTTP/1.1 201 Created\r\n",
        .no_content => "HTTP/1.1 204 No Content\r\n",
        .moved_permanently => "HTTP/1.1 301 Moved Permanently\r\n",
        .found => "HTTP/1.1 302 Found\r\n",
        .not_modified => "HTTP/1.1 304 Not Modified\r\n",
        .bad_request => "HTTP/1.1 400 Bad Request\r\n",
        .unauthorized => "HTTP/1.1 401 Unauthorized\r\n",
        .forbidden => "HTTP/1.1 403 Forbidden\r\n",
        .not_found => "HTTP/1.1 404 Not Found\r\n",
        .method_not_allowed => "HTTP/1.1 405 Method Not Allowed\r\n",
        .payload_too_large => "HTTP/1.1 413 Content Too Large\r\n",
        .teapot => "HTTP/1.1 418 I'm a Teapot\r\n",
        .too_many_requests => "HTTP/1.1 429 Too Many Requests\r\n",
        .internal_server_error => "HTTP/1.1 500 Internal Server Error\r\n",
        .bad_gateway => "HTTP/1.1 502 Bad Gateway\r\n",
        .service_unavailable => "HTTP/1.1 503 Service Unavailable\r\n",
        .gateway_timeout => "HTTP/1.1 504 Gateway Timeout\r\n",
        else => return error.UnsupportedStatus,
    };
}

// ============================================================
// Tests
// ============================================================

test "json response" {
    const r = Response.json("{\"ok\":true}");
    try std.testing.expectEqual(http.Status.ok, r.status);
    try std.testing.expectEqualStrings("application/json", r.headers[0].value);
    try std.testing.expectEqualStrings("{\"ok\":true}", r.body.?);
}

test "text response" {
    const r = Response.text("hello");
    try std.testing.expectEqual(http.Status.ok, r.status);
    try std.testing.expectEqualStrings("text/plain", r.headers[0].value);
    try std.testing.expectEqualStrings("hello", r.body.?);
}

test "redirect response" {
    const r = Response.redirect("/login");
    try std.testing.expectEqual(http.Status.found, r.status);
    try std.testing.expectEqualStrings("Location", r.headers[0].name);
    try std.testing.expectEqualStrings("/login", r.headers[0].value);
    try std.testing.expect(r.body == null);
}

test "not found response" {
    const r = Response.notFound();
    try std.testing.expectEqual(http.Status.not_found, r.status);
    try std.testing.expectEqualStrings("Not Found", r.body.?);
}

test "fluent API chaining" {
    var r = Response.init(.created);
    _ = r.setContentType("text/plain").setHeader("X-Custom", "val").setBody("created");
    try std.testing.expectEqual(http.Status.created, r.status);
    try std.testing.expectEqualStrings("created", r.body.?);
    try std.testing.expectEqual(@as(usize, 2), r.header_count);
    try std.testing.expectEqualStrings("text/plain", r.headers[0].value);
    try std.testing.expectEqualStrings("val", r.headers[1].value);
}

test "serialize to bytes" {
    const r = Response.text("hi");
    var buf: [4096]u8 = undefined;
    const n = try r.serialize(&buf);
    const out = buf[0..n];
    try std.testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "Content-Type: text/plain\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "hi"));
}
