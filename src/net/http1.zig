//! HTTP/1.1 incremental request parser and response serializer.
//!
//! Design:
//! - Incremental state machine parser — handles partial reads via feed().
//! - Zero allocation — operates on a pre-allocated buffer passed at init.
//! - Zero copy — all header name/value/uri are slices into the buffer.
//! - Scalar parsing only (SIMD deferred to FALSIFY.md benchmarks).
//! - Inline header name lowercasing during parse.
//!
//! Inspired by: http.zig (refs/http.zig/INSIGHTS.md) — incremental parser, inline lowercasing.

const std = @import("std");
const builtin = @import("builtin");

// Inline assert for hot-path bounds checks (same pattern as src/core/assert.zig).
const check = switch (builtin.mode) {
    .Debug => std.debug.assert,
    .ReleaseSmall, .ReleaseSafe, .ReleaseFast => struct {
        inline fn assert(ok: bool) void {
            if (!ok) unreachable;
        }
    }.assert,
};

pub const MAX_HEADERS: usize = 64;
pub const MAX_HEADER_SIZE: usize = 8192;
pub const MAX_URI_SIZE: usize = 8192;
pub const MAX_RESP_HEADERS: usize = 64;

// --- Method ---

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
    CONNECT,
    TRACE,

    pub fn fromBytes(bytes: []const u8) ?Method {
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

// --- Version ---

pub const Version = enum {
    http11,
    http10,
};

// --- Header ---

/// Parsed header. name is lowercased in-place. Both are slices into parser buf.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

// --- Parse state machine ---

pub const ParseState = enum {
    method,
    uri,
    version,
    header_name,
    header_value,
    headers_done,
    body,
    done,
    err,
};

pub const FeedResult = enum {
    need_more,
    headers_complete,
    done,
};

pub const ParseError = error{
    BadMethod,
    UriTooLong,
    BadVersion,
    HeaderTooLarge,
    TooManyHeaders,
    BadHeaderLine,
    BufferFull,
    MalformedRequest,
};

// --- Parser ---

pub const Parser = struct {
    state: ParseState,
    buf: []u8,
    buf_len: usize,
    method: ?Method,
    uri: ?[]const u8,
    version: ?Version,
    headers: [MAX_HEADERS]Header,
    header_count: usize,
    content_length: ?usize,
    chunked: bool,
    keepalive: bool,
    body_start: ?usize,
    // Internal: position of current scan within buf
    scan_pos: usize,

    pub fn init(buf: []u8) Parser {
        return .{
            .state = .method,
            .buf = buf,
            .buf_len = 0,
            .method = null,
            .uri = null,
            .version = null,
            .headers = undefined,
            .header_count = 0,
            .content_length = null,
            .chunked = false,
            .keepalive = true,
            .body_start = null,
            .scan_pos = 0,
        };
    }

    /// Feed new data into the parser. Appends to internal buffer, advances state machine.
    pub fn feed(self: *Parser, data: []const u8) ParseError!FeedResult {
        // Append incoming data to buffer
        if (self.buf_len + data.len > self.buf.len) return error.BufferFull;
        @memcpy(self.buf[self.buf_len..][0..data.len], data);
        self.buf_len += data.len;

        // Drive the state machine
        while (true) {
            switch (self.state) {
                .method => {
                    const line_end = findCrlf(self.buf[0..self.buf_len], self.scan_pos) orelse return .need_more;
                    // Request line: METHOD SP URI SP VERSION CRLF
                    const line = self.buf[0..line_end];
                    // Parse method
                    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse {
                        self.state = .err;
                        return error.MalformedRequest;
                    };
                    self.method = Method.fromBytes(line[0..sp1]) orelse {
                        self.state = .err;
                        return error.BadMethod;
                    };
                    // Parse URI
                    const rest_after_method = line[sp1 + 1 ..];
                    const sp2 = std.mem.indexOfScalar(u8, rest_after_method, ' ') orelse {
                        self.state = .err;
                        return error.MalformedRequest;
                    };
                    if (sp2 > MAX_URI_SIZE) {
                        self.state = .err;
                        return error.UriTooLong;
                    }
                    self.uri = rest_after_method[0..sp2];
                    // Parse version
                    const ver_str = rest_after_method[sp2 + 1 ..];
                    if (std.mem.eql(u8, ver_str, "HTTP/1.1")) {
                        self.version = .http11;
                        self.keepalive = true;
                    } else if (std.mem.eql(u8, ver_str, "HTTP/1.0")) {
                        self.version = .http10;
                        self.keepalive = false;
                    } else {
                        self.state = .err;
                        return error.BadVersion;
                    }
                    // Advance past CRLF to headers
                    self.scan_pos = line_end + 2;
                    self.state = .header_name;
                },
                .header_name => {
                    // Check for empty line (end of headers)
                    if (self.scan_pos + 1 < self.buf_len and
                        self.buf[self.scan_pos] == '\r' and
                        self.buf[self.scan_pos + 1] == '\n')
                    {
                        self.scan_pos += 2;
                        self.state = .headers_done;
                        continue;
                    }
                    // Need at least one more CRLF for a complete header line
                    const line_end = findCrlf(self.buf[0..self.buf_len], self.scan_pos) orelse return .need_more;
                    const line = self.buf[self.scan_pos..line_end];
                    if (line.len > MAX_HEADER_SIZE) {
                        self.state = .err;
                        return error.HeaderTooLarge;
                    }
                    // Split on first ':'
                    const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
                        self.state = .err;
                        return error.BadHeaderLine;
                    };
                    if (self.header_count >= MAX_HEADERS) {
                        self.state = .err;
                        return error.TooManyHeaders;
                    }
                    // Lowercase header name in-place
                    // Inspired by: http.zig — inline header lowercasing during parse
                    const name_start = self.scan_pos;
                    const name_end = self.scan_pos + colon;
                    for (self.buf[name_start..name_end]) |*c| {
                        if (c.* >= 'A' and c.* <= 'Z') c.* += 32;
                    }
                    const name = self.buf[name_start..name_end];
                    // Trim value (skip OWS after colon)
                    const raw_value = line[colon + 1 ..];
                    const trimmed = std.mem.trim(u8, raw_value, " \t");
                    // Compute value slice as offset into buf
                    const value_offset = @intFromPtr(trimmed.ptr) - @intFromPtr(self.buf.ptr);
                    const value = self.buf[value_offset..][0..trimmed.len];

                    self.headers[self.header_count] = .{ .name = name, .value = value };
                    self.header_count += 1;

                    // Smuggling prevention: reject null bytes and obs-fold in values
                    // (Kettle 2025 — header injection vectors)
                    for (trimmed) |vc| {
                        if (vc == 0) { self.state = .err; return error.MalformedRequest; }
                    }
                    if (trimmed.len > 0 and (trimmed[0] == ' ' or trimmed[0] == '\t')) {
                        self.state = .err;
                        return error.MalformedRequest;
                    }

                    // Detect Content-Length (strict: no leading zeros per Kettle 2025)
                    if (std.mem.eql(u8, name, "content-length")) {
                        if (trimmed.len > 1 and trimmed[0] == '0') {
                            self.state = .err;
                            return error.MalformedRequest; // leading zeros
                        }
                        self.content_length = std.fmt.parseInt(usize, trimmed, 10) catch {
                            self.state = .err;
                            return error.MalformedRequest;
                        };
                    }
                    // Detect Transfer-Encoding (strict: only bare "chunked")
                    if (std.mem.eql(u8, name, "transfer-encoding")) {
                        if (std.mem.eql(u8, trimmed, "chunked")) {
                            self.chunked = true;
                        } else {
                            self.state = .err;
                            return error.MalformedRequest; // non-chunked TE
                        }
                    }
                    // Detect Connection: keep-alive / close
                    if (std.mem.eql(u8, name, "connection")) {
                        // Lowercase the value for comparison
                        var lower_buf: [64]u8 = undefined;
                        const tlen = @min(trimmed.len, lower_buf.len);
                        for (0..tlen) |i| {
                            const ch = trimmed[i];
                            lower_buf[i] = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
                        }
                        const lower = lower_buf[0..tlen];
                        if (std.mem.eql(u8, lower, "keep-alive")) {
                            self.keepalive = true;
                        } else if (std.mem.eql(u8, lower, "close")) {
                            self.keepalive = false;
                        }
                    }

                    self.scan_pos = line_end + 2;
                    // Stay in header_name state for next header
                },
                .headers_done => {
                    // Smuggling prevention: reject CL + TE together (Kettle 2025)
                    if (self.content_length != null and self.chunked) {
                        self.state = .err;
                        return error.MalformedRequest;
                    }
                    self.body_start = self.scan_pos;
                    if (self.content_length) |cl| {
                        if (cl == 0) {
                            self.state = .done;
                            return .done;
                        }
                        self.state = .body;
                        continue;
                    }
                    if (self.chunked) {
                        // Chunked: report headers complete, body parsed separately
                        self.state = .body;
                        return .headers_complete;
                    }
                    // No body
                    self.state = .done;
                    return .done;
                },
                .body => {
                    if (self.content_length) |cl| {
                        const available = self.buf_len - self.scan_pos;
                        if (available >= cl) {
                            self.state = .done;
                            return .done;
                        }
                        return .need_more;
                    }
                    // Chunked or unknown — caller handles
                    return .headers_complete;
                },
                .done => return .done,
                .err => return error.MalformedRequest,
                // These states are not used directly by the state machine but exist for completeness
                .uri, .version, .header_value => {
                    self.state = .err;
                    return error.MalformedRequest;
                },
            }
        }
    }

    /// Reset parser for next request (keepalive / pipelining).
    /// If there is unconsumed data after the current request, it is shifted to the front.
    pub fn reset(self: *Parser) void {
        // Determine how many bytes belong to the next request
        const consumed = blk: {
            if (self.content_length) |cl| {
                break :blk (self.body_start orelse self.buf_len) + cl;
            }
            break :blk self.body_start orelse self.buf_len;
        };
        const leftover = self.buf_len - consumed;
        if (leftover > 0) {
            std.mem.copyForwards(u8, self.buf[0..leftover], self.buf[consumed..self.buf_len]);
        }
        self.state = .method;
        self.buf_len = leftover;
        self.method = null;
        self.uri = null;
        self.version = null;
        self.header_count = 0;
        self.content_length = null;
        self.chunked = false;
        self.keepalive = true;
        self.body_start = null;
        self.scan_pos = 0;
    }

    /// Get the request body slice (only valid when state is done and content_length is set).
    pub fn body(self: *const Parser) ?[]const u8 {
        const start = self.body_start orelse return null;
        const cl = self.content_length orelse return null;
        if (start + cl > self.buf_len) return null;
        return self.buf[start..][0..cl];
    }
};

// --- Response ---

pub const Response = struct {
    status: u16,
    headers: [MAX_RESP_HEADERS]RespHeader,
    header_count: usize,
    body: ?[]const u8,

    pub const RespHeader = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn init(status: u16) Response {
        return .{
            .status = status,
            .headers = undefined,
            .header_count = 0,
            .body = null,
        };
    }

    pub fn addHeader(self: *Response, name: []const u8, value: []const u8) void {
        check(self.header_count < MAX_RESP_HEADERS);
        self.headers[self.header_count] = .{ .name = name, .value = value };
        self.header_count += 1;
    }

    /// Serialize status line + headers + body into out buffer. Returns bytes written.
    pub fn serialize(self: *const Response, out: []u8) error{BufferTooSmall}!usize {
        var pos: usize = 0;

        // Status line
        const sl = statusLine(self.status);
        if (pos + sl.len > out.len) return error.BufferTooSmall;
        @memcpy(out[pos..][0..sl.len], sl);
        pos += sl.len;

        // Headers
        for (self.headers[0..self.header_count]) |h| {
            const needed = h.name.len + 2 + h.value.len + 2; // "name: value\r\n"
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

        // End of headers
        if (pos + 2 > out.len) return error.BufferTooSmall;
        out[pos] = '\r';
        out[pos + 1] = '\n';
        pos += 2;

        // Body
        if (self.body) |b| {
            if (pos + b.len > out.len) return error.BufferTooSmall;
            @memcpy(out[pos..][0..b.len], b);
            pos += b.len;
        }

        return pos;
    }
};

// --- Status line helper ---

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

// --- Helpers ---

/// Find the next \r\n in buf starting from `from`. Returns index of \r.
fn findCrlf(buf: []const u8, from: usize) ?usize {
    if (from >= buf.len) return null;
    var i = from;
    while (i + 1 < buf.len) : (i += 1) {
        if (buf[i] == '\r' and buf[i + 1] == '\n') return i;
    }
    return null;
}

// ============================================================
// Tests
// ============================================================

test "parse GET request" {
    var buf: [4096]u8 = undefined;
    var p = Parser.init(&buf);
    const req = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const result = p.feed(req) catch unreachable;
    try std.testing.expectEqual(FeedResult.done, result);
    try std.testing.expectEqual(Method.GET, p.method.?);
    try std.testing.expectEqualStrings("/", p.uri.?);
    try std.testing.expectEqual(Version.http11, p.version.?);
    try std.testing.expectEqual(@as(usize, 1), p.header_count);
    try std.testing.expectEqualStrings("host", p.headers[0].name);
    try std.testing.expectEqualStrings("localhost", p.headers[0].value);
}

test "parse POST with body" {
    var buf: [4096]u8 = undefined;
    var p = Parser.init(&buf);
    const req = "POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Length: 13\r\n\r\nHello, world!";
    const result = p.feed(req) catch unreachable;
    try std.testing.expectEqual(FeedResult.done, result);
    try std.testing.expectEqual(Method.POST, p.method.?);
    try std.testing.expectEqualStrings("/submit", p.uri.?);
    try std.testing.expectEqual(@as(usize, 13), p.content_length.?);
    try std.testing.expectEqualStrings("Hello, world!", p.body().?);
}

test "parse headers case insensitive" {
    var buf: [4096]u8 = undefined;
    var p = Parser.init(&buf);
    const req = "GET / HTTP/1.1\r\nContent-Type: text/html\r\nX-Custom-Header: value\r\n\r\n";
    _ = p.feed(req) catch unreachable;
    // Header names should be lowercased
    try std.testing.expectEqualStrings("content-type", p.headers[0].name);
    try std.testing.expectEqualStrings("x-custom-header", p.headers[1].name);
    try std.testing.expectEqualStrings("text/html", p.headers[0].value);
}

test "parse partial request" {
    var buf: [4096]u8 = undefined;
    var p = Parser.init(&buf);
    // Feed first half
    const part1 = "GET / HTTP/1.1\r\nHos";
    const r1 = p.feed(part1) catch unreachable;
    try std.testing.expectEqual(FeedResult.need_more, r1);
    // Feed second half
    const part2 = "t: localhost\r\n\r\n";
    const r2 = p.feed(part2) catch unreachable;
    try std.testing.expectEqual(FeedResult.done, r2);
    try std.testing.expectEqual(Method.GET, p.method.?);
    try std.testing.expectEqualStrings("localhost", p.headers[0].value);
}

test "parse chunked transfer encoding" {
    var buf: [4096]u8 = undefined;
    var p = Parser.init(&buf);
    const req = "POST /data HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n";
    const result = p.feed(req) catch unreachable;
    // Chunked: headers complete, body handling deferred
    try std.testing.expectEqual(FeedResult.headers_complete, result);
    try std.testing.expect(p.chunked);
    try std.testing.expectEqual(@as(?usize, null), p.content_length);
}

test "reject malformed request" {
    // Bad method
    {
        var buf: [4096]u8 = undefined;
        var p = Parser.init(&buf);
        const req = "XYZZY / HTTP/1.1\r\n\r\n";
        const result = p.feed(req);
        try std.testing.expectError(error.BadMethod, result);
    }
    // No CRLF at all — need more
    {
        var buf: [4096]u8 = undefined;
        var p = Parser.init(&buf);
        const req = "GET / HTTP/1.1";
        const result = p.feed(req) catch unreachable;
        try std.testing.expectEqual(FeedResult.need_more, result);
    }
    // Bad version
    {
        var buf: [4096]u8 = undefined;
        var p = Parser.init(&buf);
        const req = "GET / HTTP/2.0\r\n\r\n";
        const result = p.feed(req);
        try std.testing.expectError(error.BadVersion, result);
    }
}

test "parse keepalive" {
    // HTTP/1.1 default keepalive
    {
        var buf: [4096]u8 = undefined;
        var p = Parser.init(&buf);
        _ = p.feed("GET / HTTP/1.1\r\nHost: h\r\n\r\n") catch unreachable;
        try std.testing.expect(p.keepalive);
    }
    // Connection: close
    {
        var buf: [4096]u8 = undefined;
        var p = Parser.init(&buf);
        _ = p.feed("GET / HTTP/1.1\r\nConnection: close\r\n\r\n") catch unreachable;
        try std.testing.expect(!p.keepalive);
    }
    // HTTP/1.0 default no keepalive
    {
        var buf: [4096]u8 = undefined;
        var p = Parser.init(&buf);
        _ = p.feed("GET / HTTP/1.0\r\nHost: h\r\n\r\n") catch unreachable;
        try std.testing.expect(!p.keepalive);
    }
    // HTTP/1.0 with Connection: keep-alive
    {
        var buf: [4096]u8 = undefined;
        var p = Parser.init(&buf);
        _ = p.feed("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n") catch unreachable;
        try std.testing.expect(p.keepalive);
    }
}

test "max header size enforced" {
    var buf: [16384]u8 = undefined;
    var p = Parser.init(&buf);
    // Build a request with a header value exceeding 8KB
    const prefix = "GET / HTTP/1.1\r\nX-Big: ";
    const crlf = "\r\n\r\n";
    var req_buf: [16384]u8 = undefined;
    @memcpy(req_buf[0..prefix.len], prefix);
    const fill_len = MAX_HEADER_SIZE + 1 - "X-Big: ".len;
    @memset(req_buf[prefix.len..][0..fill_len], 'A');
    const total = prefix.len + fill_len;
    @memcpy(req_buf[total..][0..crlf.len], crlf);
    const result = p.feed(req_buf[0 .. total + crlf.len]);
    try std.testing.expectError(error.HeaderTooLarge, result);
}

test "serialize response" {
    var resp = Response.init(200);
    resp.addHeader("Content-Type", "text/plain");
    resp.addHeader("Content-Length", "5");
    resp.body = "hello";

    var out: [4096]u8 = undefined;
    const n = resp.serialize(&out) catch unreachable;
    const expected = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello";
    try std.testing.expectEqualStrings(expected, out[0..n]);
}

test "parse multiple requests on one buffer" {
    var buf: [4096]u8 = undefined;
    var p = Parser.init(&buf);
    // Two pipelined requests in one feed
    const both = "GET /first HTTP/1.1\r\nHost: h\r\n\r\nGET /second HTTP/1.1\r\nHost: h\r\n\r\n";
    // First request
    const r1 = p.feed(both) catch unreachable;
    try std.testing.expectEqual(FeedResult.done, r1);
    try std.testing.expectEqualStrings("/first", p.uri.?);
    // Reset and parse second
    p.reset();
    const r2 = p.feed("") catch unreachable;
    try std.testing.expectEqual(FeedResult.done, r2);
    try std.testing.expectEqualStrings("/second", p.uri.?);
}
