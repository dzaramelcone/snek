//! Higher-level HTTP response builder with fluent API.
//!
//! SEPARATE from net/http1.zig's Response — that one is a low-level serializer,
//! this one is the user-facing API with convenience constructors.
//! Self-contained: inlines serialization so it can be tested standalone.

const std = @import("std");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

const MAX_HEADERS: usize = 32;

pub const Response = struct {
    status: u16,
    headers: [MAX_HEADERS]Header,
    header_count: usize,
    body: ?[]const u8,

    pub fn init(status: u16) Response {
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
        var r = init(200);
        _ = r.setContentType("application/json");
        r.body = b;
        return r;
    }

    /// 200 + text/plain
    pub fn text(b: []const u8) Response {
        var r = init(200);
        _ = r.setContentType("text/plain");
        r.body = b;
        return r;
    }

    /// 200 + text/html
    pub fn html(b: []const u8) Response {
        var r = init(200);
        _ = r.setContentType("text/html");
        r.body = b;
        return r;
    }

    /// 302 + Location header
    pub fn redirect(location: []const u8) Response {
        var r = init(302);
        _ = r.setHeader("Location", location);
        return r;
    }

    /// 404 Not Found
    pub fn notFound() Response {
        var r = init(404);
        r.body = "Not Found";
        return r;
    }

    /// 405 + Allow header
    pub fn methodNotAllowed(allowed: []const u8) Response {
        var r = init(405);
        _ = r.setHeader("Allow", allowed);
        r.body = "Method Not Allowed";
        return r;
    }

    /// Serialize to HTTP/1.1 response bytes.
    pub fn serialize(self: *const Response, buf: []u8) error{BufferTooSmall}!usize {
        var pos: usize = 0;

        // Status line
        const sl = statusLine(self.status);
        if (pos + sl.len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[pos..][0..sl.len], sl);
        pos += sl.len;

        // Headers
        for (self.headers[0..self.header_count]) |h| {
            const needed = h.name.len + 2 + h.value.len + 2;
            if (pos + needed > buf.len) return error.BufferTooSmall;
            @memcpy(buf[pos..][0..h.name.len], h.name);
            pos += h.name.len;
            buf[pos] = ':';
            buf[pos + 1] = ' ';
            pos += 2;
            @memcpy(buf[pos..][0..h.value.len], h.value);
            pos += h.value.len;
            buf[pos] = '\r';
            buf[pos + 1] = '\n';
            pos += 2;
        }

        // End of headers
        if (pos + 2 > buf.len) return error.BufferTooSmall;
        buf[pos] = '\r';
        buf[pos + 1] = '\n';
        pos += 2;

        // Body
        if (self.body) |b| {
            if (pos + b.len > buf.len) return error.BufferTooSmall;
            @memcpy(buf[pos..][0..b.len], b);
            pos += b.len;
        }
        return pos;
    }
};

fn statusLine(code: u16) []const u8 {
    return switch (code) {
        200 => "HTTP/1.1 200 OK\r\n",
        201 => "HTTP/1.1 201 Created\r\n",
        204 => "HTTP/1.1 204 No Content\r\n",
        301 => "HTTP/1.1 301 Moved Permanently\r\n",
        302 => "HTTP/1.1 302 Found\r\n",
        304 => "HTTP/1.1 304 Not Modified\r\n",
        400 => "HTTP/1.1 400 Bad Request\r\n",
        404 => "HTTP/1.1 404 Not Found\r\n",
        405 => "HTTP/1.1 405 Method Not Allowed\r\n",
        500 => "HTTP/1.1 500 Internal Server Error\r\n",
        else => "HTTP/1.1 200 OK\r\n",
    };
}

// ============================================================
// Tests
// ============================================================

test "json response" {
    const r = Response.json("{\"ok\":true}");
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("application/json", r.headers[0].value);
    try std.testing.expectEqualStrings("{\"ok\":true}", r.body.?);
}

test "text response" {
    const r = Response.text("hello");
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("text/plain", r.headers[0].value);
    try std.testing.expectEqualStrings("hello", r.body.?);
}

test "redirect response" {
    const r = Response.redirect("/login");
    try std.testing.expectEqual(@as(u16, 302), r.status);
    try std.testing.expectEqualStrings("Location", r.headers[0].name);
    try std.testing.expectEqualStrings("/login", r.headers[0].value);
    try std.testing.expect(r.body == null);
}

test "not found response" {
    const r = Response.notFound();
    try std.testing.expectEqual(@as(u16, 404), r.status);
    try std.testing.expectEqualStrings("Not Found", r.body.?);
}

test "fluent API chaining" {
    var r = Response.init(201);
    _ = r.setContentType("text/plain").setHeader("X-Custom", "val").setBody("created");
    try std.testing.expectEqual(@as(u16, 201), r.status);
    try std.testing.expectEqualStrings("created", r.body.?);
    try std.testing.expectEqual(@as(usize, 2), r.header_count);
    try std.testing.expectEqualStrings("text/plain", r.headers[0].value);
    try std.testing.expectEqualStrings("val", r.headers[1].value);
}

test "serialize to bytes" {
    const r = Response.text("hi");
    var buf: [4096]u8 = undefined;
    const n = r.serialize(&buf) catch unreachable;
    const out = buf[0..n];
    try std.testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "Content-Type: text/plain\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "hi"));
}
