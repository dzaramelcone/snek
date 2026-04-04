//! HTTP/1.1 request parser and response serializer.
//!
//! Parser takes a complete header block as []const u8, tokenizes in one pass.
//! All parsed fields are slices into the input — zero copy, zero allocation.

const std = @import("std");
const builtin = @import("builtin");

pub const MAX_HEADERS: usize = 64;
pub const MAX_RESP_HEADERS: usize = 64;

pub const Method = enum {
    GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS, CONNECT, TRACE,

    pub fn fromBytes(bytes: []const u8) ?Method {
        if (bytes.len < 3 or bytes.len > 7) return null;
        if (std.mem.eql(u8, bytes, "GET")) return .GET;
        if (std.mem.eql(u8, bytes, "POST")) return .POST;
        if (std.mem.eql(u8, bytes, "PUT")) return .PUT;
        if (std.mem.eql(u8, bytes, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, bytes, "PATCH")) return .PATCH;
        if (std.mem.eql(u8, bytes, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, bytes, "OPTIONS")) return .OPTIONS;
        if (std.mem.eql(u8, bytes, "CONNECT")) return .CONNECT;
        if (std.mem.eql(u8, bytes, "TRACE")) return .TRACE;
        return null;
    }
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const ParseError = error{
    MalformedRequest,
    BadMethod,
    BadVersion,
    UriTooLong,
    TooManyHeaders,
    HeaderTooLarge,
    BadHeaderLine,
    BufferFull,
};

pub const Request = struct {
    method: ?Method = null,
    method_bytes: ?[]const u8 = null,
    uri: ?[]const u8 = null,
    headers: [MAX_HEADERS]Header = undefined,
    header_count: usize = 0,
    content_length: ?usize = null,
    keepalive: bool = true,
    body: ?[]const u8 = null,

    /// Parse a complete header block. `bytes` must end at (or include) the \r\n\r\n.
    /// All returned slices point into `bytes`.
    pub fn parse(bytes: []const u8) ParseError!Request {
        var req = Request{};
        var lines = std.mem.splitSequence(u8, bytes, "\r\n");

        // Request line: METHOD SP URI SP VERSION
        const request_line = lines.next() orelse return error.MalformedRequest;
        var chunks = std.mem.tokenizeScalar(u8, request_line, ' ');

        const method_str = chunks.next() orelse return error.MalformedRequest;
        req.method = Method.fromBytes(method_str) orelse return error.BadMethod;
        req.method_bytes = method_str;

        const uri = chunks.next() orelse return error.MalformedRequest;
        req.uri = uri;

        const version = chunks.next() orelse return error.MalformedRequest;
        if (std.mem.eql(u8, version, "HTTP/1.1")) {
            req.keepalive = true;
        } else if (std.mem.eql(u8, version, "HTTP/1.0")) {
            req.keepalive = false;
        } else return error.BadVersion;

        if (chunks.next() != null) return error.MalformedRequest;

        // Headers
        while (lines.next()) |line| {
            if (line.len == 0) break; // empty line = end of headers
            if (req.header_count >= MAX_HEADERS) return error.TooManyHeaders;

            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadHeaderLine;
            const name = line[0..colon];
            const value = std.mem.trimLeft(u8, line[colon + 1 ..], " \t");
            if (value.len == 0) return error.BadHeaderLine;

            req.headers[req.header_count] = .{ .name = name, .value = value };
            req.header_count += 1;

            // Content-Length
            if (eqlIgnoreCase(name, "Content-Length")) {
                req.content_length = std.fmt.parseInt(usize, value, 10) catch
                    return error.MalformedRequest;
            }
            // Connection
            if (eqlIgnoreCase(name, "Connection")) {
                if (eqlIgnoreCase(value, "close")) req.keepalive = false;
                if (eqlIgnoreCase(value, "keep-alive")) req.keepalive = true;
            }
        }

        // Body: everything after headers in the input
        const rest = lines.rest();
        if (rest.len > 0) {
            req.body = rest;
        }

        return req;
    }
};

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}


// --- Response ---

pub const Response = struct {
    status: u16,
    headers: [MAX_RESP_HEADERS]Header,
    header_count: usize,
    body: ?[]const u8,

    pub fn init(status: u16) Response {
        return .{ .status = status, .headers = undefined, .header_count = 0, .body = null };
    }

    pub fn json(body_str: []const u8) Response {
        var r = init(200);
        r.setContentType("application/json");
        r.body = body_str;
        return r;
    }

    pub fn text(body_str: []const u8) Response {
        var r = init(200);
        r.setContentType("text/plain");
        r.body = body_str;
        return r;
    }

    pub fn notFound() Response {
        return init(404);
    }

    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) void {
        if (self.header_count >= MAX_RESP_HEADERS) return;
        self.headers[self.header_count] = .{ .name = name, .value = value };
        self.header_count += 1;
    }

    pub fn setContentType(self: *Response, ct: []const u8) void {
        self.setHeader("Content-Type", ct);
    }

    pub fn setBody(self: *Response, b: []const u8) void {
        self.body = b;
    }

    pub fn serialize(self: *const Response, out: []u8) error{BufferTooSmall}!usize {
        var pos: usize = 0;

        const sl = statusLine(self.status);
        if (pos + sl.len > out.len) return error.BufferTooSmall;
        @memcpy(out[pos..][0..sl.len], sl);
        pos += sl.len;

        // Content-Length header (auto)
        if (self.body) |b| {
            const cl_header = "Content-Length: ";
            if (pos + cl_header.len > out.len) return error.BufferTooSmall;
            @memcpy(out[pos..][0..cl_header.len], cl_header);
            pos += cl_header.len;
            const cl_str = std.fmt.bufPrint(out[pos..], "{d}", .{b.len}) catch return error.BufferTooSmall;
            pos += cl_str.len;
            if (pos + 2 > out.len) return error.BufferTooSmall;
            out[pos] = '\r';
            out[pos + 1] = '\n';
            pos += 2;
        }

        for (self.headers[0..self.header_count]) |h| {
            const needed = h.name.len + 2 + h.value.len + 2;
            if (pos + needed > out.len) return error.BufferTooSmall;
            @memcpy(out[pos..][0..h.name.len], h.name);
            pos += h.name.len;
            out[pos] = ':';
            out[pos + 1] = ' ';
            pos += 2;
            @memcpy(out[pos..][0..h.value.len], h.value);
            pos += h.value.len;
            out[pos] = '\r';
            out[pos + 1] = '\n';
            pos += 2;
        }

        if (pos + 2 > out.len) return error.BufferTooSmall;
        out[pos] = '\r';
        out[pos + 1] = '\n';
        pos += 2;

        if (self.body) |b| {
            if (pos + b.len > out.len) return error.BufferTooSmall;
            @memcpy(out[pos..][0..b.len], b);
            pos += b.len;
        }

        return pos;
    }
};

pub fn statusLine(code: u16) []const u8 {
    return switch (code) {
        200 => "HTTP/1.1 200 OK\r\n",
        201 => "HTTP/1.1 201 Created\r\n",
        204 => "HTTP/1.1 204 No Content\r\n",
        301 => "HTTP/1.1 301 Moved Permanently\r\n",
        302 => "HTTP/1.1 302 Found\r\n",
        304 => "HTTP/1.1 304 Not Modified\r\n",
        400 => "HTTP/1.1 400 Bad Request\r\n",
        401 => "HTTP/1.1 401 Unauthorized\r\n",
        403 => "HTTP/1.1 403 Forbidden\r\n",
        404 => "HTTP/1.1 404 Not Found\r\n",
        405 => "HTTP/1.1 405 Method Not Allowed\r\n",
        413 => "HTTP/1.1 413 Content Too Large\r\n",
        500 => "HTTP/1.1 500 Internal Server Error\r\n",
        502 => "HTTP/1.1 502 Bad Gateway\r\n",
        503 => "HTTP/1.1 503 Service Unavailable\r\n",
        else => "HTTP/1.1 200 OK\r\n",
    };
}

// --- Tests ---

test "parse GET request" {
    const req = try Request.parse("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try std.testing.expectEqual(Method.GET, req.method.?);
    try std.testing.expectEqualStrings("/", req.uri.?);
    try std.testing.expectEqual(@as(usize, 1), req.header_count);
    try std.testing.expectEqualStrings("Host", req.headers[0].name);
    try std.testing.expectEqualStrings("localhost", req.headers[0].value);
    try std.testing.expect(req.keepalive);
}

test "parse POST with body" {
    const raw = "POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Length: 13\r\n\r\nHello, world!";
    const req = try Request.parse(raw);
    try std.testing.expectEqual(Method.POST, req.method.?);
    try std.testing.expectEqualStrings("/submit", req.uri.?);
    try std.testing.expectEqual(@as(usize, 13), req.content_length.?);
    try std.testing.expectEqualStrings("Hello, world!", req.body.?);
}

test "parse headers case insensitive matching" {
    const req = try Request.parse("GET / HTTP/1.1\r\nContent-Type: text/html\r\nX-Custom: value\r\n\r\n");
    try std.testing.expectEqualStrings("Content-Type", req.headers[0].name);
    try std.testing.expectEqualStrings("text/html", req.headers[0].value);
}

test "reject bad method" {
    try std.testing.expectError(error.BadMethod, Request.parse("XYZZY / HTTP/1.1\r\n\r\n"));
}

test "reject bad version" {
    try std.testing.expectError(error.BadVersion, Request.parse("GET / HTTP/2.0\r\n\r\n"));
}

test "keepalive detection" {
    {
        const req = try Request.parse("GET / HTTP/1.1\r\nHost: h\r\n\r\n");
        try std.testing.expect(req.keepalive);
    }
    {
        const req = try Request.parse("GET / HTTP/1.1\r\nConnection: close\r\n\r\n");
        try std.testing.expect(!req.keepalive);
    }
    {
        const req = try Request.parse("GET / HTTP/1.0\r\nHost: h\r\n\r\n");
        try std.testing.expect(!req.keepalive);
    }
    {
        const req = try Request.parse("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n");
        try std.testing.expect(req.keepalive);
    }
}

test "serialize response" {
    var resp = Response.init(200);
    resp.setContentType("text/plain");
    resp.body = "hello";

    var out: [4096]u8 = undefined;
    const n = try resp.serialize(&out);
    const expected = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Type: text/plain\r\n\r\nhello";
    try std.testing.expectEqualStrings(expected, out[0..n]);
}
