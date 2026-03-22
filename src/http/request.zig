//! Higher-level HTTP request object built from parsed HTTP/1.1 data.
//!
//! Wraps the low-level net/http1.Parser result into a user-friendly API
//! with lazy query string parsing, case-insensitive header lookup, and
//! route parameter access.
//!
//! NOTE: Defines its own types to stay self-contained. The fromRaw()
//! constructor accepts raw parsed fields (method, uri, headers, body)
//! so any parser can feed it.

const std = @import("std");

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
};

pub const Version = enum { http11, http10 };

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const PathParam = struct {
    name: []const u8,
    value: []const u8,
};

pub const QueryParam = struct {
    name: []const u8,
    value: []const u8,
};

const MAX_QUERY_PARAMS: usize = 32;

pub const Request = struct {
    method: Method,
    path: []const u8,
    version: Version,
    headers: []const Header,
    body: ?[]const u8,

    // Lazy-parsed query cache
    _query: ?[MAX_QUERY_PARAMS]QueryParam = null,
    _query_count: usize = 0,
    _query_raw: ?[]const u8 = null,

    // Route params (set by router after match)
    params: [8]PathParam = undefined,
    param_count: u8 = 0,

    /// Build from raw parsed fields (method string, full URI, header pairs, body).
    pub fn fromRaw(
        method: Method,
        uri: []const u8,
        version: Version,
        headers: []const Header,
        body_slice: ?[]const u8,
    ) Request {
        const qmark = std.mem.indexOfScalar(u8, uri, '?');
        return .{
            .method = method,
            .path = if (qmark) |q| uri[0..q] else uri,
            .version = version,
            .headers = headers,
            .body = body_slice,
            ._query_raw = if (qmark) |q| uri[q + 1 ..] else null,
        };
    }

    /// Get a route parameter by name.
    pub fn param(self: *const Request, name: []const u8) ?[]const u8 {
        for (self.params[0..self.param_count]) |p| {
            if (std.mem.eql(u8, p.name, name)) return p.value;
        }
        return null;
    }

    /// Get a header value by name (case-insensitive).
    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    /// Get the raw query string (everything after ?).
    pub fn queryString(self: *const Request) ?[]const u8 {
        return self._query_raw;
    }

    /// Get a query parameter by name (lazy-parsed on first access).
    pub fn query(self: *Request, name: []const u8) ?[]const u8 {
        if (self._query == null) self.parseQuery();
        if (self._query) |q| {
            for (q[0..self._query_count]) |p| {
                if (std.mem.eql(u8, p.name, name)) return p.value;
            }
        }
        return null;
    }

    /// Content-Type header value.
    pub fn contentType(self: *const Request) ?[]const u8 {
        return self.header("content-type");
    }

    /// Content-Length as integer.
    pub fn contentLength(self: *const Request) ?usize {
        const val = self.header("content-length") orelse return null;
        return std.fmt.parseInt(usize, val, 10) catch null;
    }

    fn parseQuery(self: *Request) void {
        const raw = self._query_raw orelse return;
        var q: [MAX_QUERY_PARAMS]QueryParam = undefined;
        var count: usize = 0;
        var iter = std.mem.splitScalar(u8, raw, '&');
        while (iter.next()) |pair| {
            if (count >= MAX_QUERY_PARAMS) break;
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                q[count] = .{ .name = pair[0..eq], .value = pair[eq + 1 ..] };
            } else {
                q[count] = .{ .name = pair, .value = "" };
            }
            count += 1;
        }
        self._query = q;
        self._query_count = count;
    }
};

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        const al: u8 = if (ac >= 'A' and ac <= 'Z') ac + 32 else ac;
        const bl: u8 = if (bc >= 'A' and bc <= 'Z') bc + 32 else bc;
        if (al != bl) return false;
    }
    return true;
}

// ============================================================
// Tests
// ============================================================

test "fromRaw extracts method, path, headers" {
    const hdrs = [_]Header{
        .{ .name = "host", .value = "example.com" },
        .{ .name = "accept", .value = "text/html" },
    };
    const req = Request.fromRaw(.GET, "/hello", .http11, &hdrs, null);
    try std.testing.expectEqual(Method.GET, req.method);
    try std.testing.expectEqualStrings("/hello", req.path);
    try std.testing.expectEqual(Version.http11, req.version);
    try std.testing.expectEqual(@as(usize, 2), req.headers.len);
    try std.testing.expectEqualStrings("example.com", req.headers[0].value);
}

test "param lookup by name" {
    var req = Request.fromRaw(.GET, "/users/42", .http11, &.{}, null);
    req.params[0] = .{ .name = "id", .value = "42" };
    req.params[1] = .{ .name = "action", .value = "edit" };
    req.param_count = 2;
    try std.testing.expectEqualStrings("42", req.param("id").?);
    try std.testing.expectEqualStrings("edit", req.param("action").?);
    try std.testing.expect(req.param("missing") == null);
}

test "header lookup case-insensitive" {
    const hdrs = [_]Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "x-request-id", .value = "abc123" },
    };
    const req = Request.fromRaw(.GET, "/", .http11, &hdrs, null);
    try std.testing.expectEqualStrings("application/json", req.header("Content-Type").?);
    try std.testing.expectEqualStrings("abc123", req.header("x-request-id").?);
    try std.testing.expect(req.header("nonexistent") == null);
}

test "query string parsing" {
    var req = Request.fromRaw(.GET, "/search?q=zig&page=2&sort=", .http11, &.{}, null);
    try std.testing.expectEqualStrings("/search", req.path);
    try std.testing.expectEqualStrings("q=zig&page=2&sort=", req.queryString().?);
    try std.testing.expectEqualStrings("zig", req.query("q").?);
    try std.testing.expectEqualStrings("2", req.query("page").?);
    try std.testing.expectEqualStrings("", req.query("sort").?);
    try std.testing.expect(req.query("missing") == null);
}

test "content-type and content-length helpers" {
    const hdrs = [_]Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "content-length", .value = "42" },
    };
    const req = Request.fromRaw(.POST, "/data", .http11, &hdrs, null);
    try std.testing.expectEqualStrings("application/json", req.contentType().?);
    try std.testing.expectEqual(@as(?usize, 42), req.contentLength());
}
