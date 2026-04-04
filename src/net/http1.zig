//! HTTP/1.1 request parser.
//!
//! Takes a complete header block as []const u8, tokenizes in one pass.
//! All parsed fields are slices into the input — zero copy, zero allocation.

const std = @import("std");
pub const MAX_HEADERS: usize = 64;

const COMMON_RESPONSE_HDR_CAP = 64;

threadlocal var cached_common_response_hdr: [COMMON_RESPONSE_HDR_CAP]u8 = undefined;
threadlocal var cached_common_response_len: usize = 0;
threadlocal var cached_common_response_epoch: i64 = 0;

pub const Method = std.http.Method;

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
        req.method = std.meta.stringToEnum(Method, method_str) orelse return error.BadMethod;
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

fn refreshCommonResponseHeaders() void {
    const now = std.time.timestamp();
    if (now == cached_common_response_epoch and cached_common_response_len > 0) return;
    cached_common_response_epoch = now;

    const epoch_secs: u64 = @intCast(now);
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day_secs = es.getDaySeconds();
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const day_names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    const days_since_epoch = es.getEpochDay().day;
    const dow = @mod(days_since_epoch + 3, 7);

    const hour = day_secs.getHoursIntoDay();
    const minute = day_secs.getMinutesIntoHour();
    const second = day_secs.getSecondsIntoMinute();

    cached_common_response_len = (std.fmt.bufPrint(
        &cached_common_response_hdr,
        "Server: snek\r\nDate: {s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT\r\n",
        .{
            day_names[dow],
            month_day.day_index + 1,
            month_names[month_day.month.numeric() - 1],
            year_day.year,
            hour,
            minute,
            second,
        },
    ) catch &.{}).len;
}

pub fn commonResponseHeaders() []const u8 {
    refreshCommonResponseHeaders();
    return cached_common_response_hdr[0..cached_common_response_len];
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
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

test "cached common response headers" {
    const hdr = commonResponseHeaders();
    try std.testing.expect(hdr.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, hdr, "Server: snek\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, hdr, "Date:") != null);
    try std.testing.expect(std.mem.endsWith(u8, hdr, "GMT\r\n"));
}

test "cached response headers stable within same second" {
    const a = commonResponseHeaders();
    const b = commonResponseHeaders();
    try std.testing.expectEqualStrings(a, b);
}
