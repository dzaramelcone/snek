//! Request smuggling detection and prevention.
//!
//! Dedicated module for strict Content-Length / Transfer-Encoding validation
//! and HTTP desync detection. First-class concern per Kettle 2025 research
//! (24 million sites exposed to CL/TE desync attacks).
//!
//! Reference: James Kettle, "Browser-Powered Desync Attacks" (2025).
//! Reference: RFC 9112 Section 6.3 (Message Body Length).

const std = @import("std");
const mem = std.mem;

/// Simple header for smuggling validation (name/value slices).
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// HTTP method — matches http1.zig Method enum.
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
    UNKNOWN,
};

/// Result of smuggling validation.
pub const BodyFraming = enum {
    /// No body (e.g., GET, HEAD, or 204/304 response).
    none,
    /// Body length determined by Content-Length header.
    content_length,
    /// Body is chunked transfer encoded.
    chunked,
};

/// Smuggling detection errors.
// Inspired by: Kettle 2025 "HTTP/1.1 Must Die" (src/net/REFERENCES.md) — strict CL/TE validation against desync attacks
// See: RFC 9112 §6.3 — Message Body Length determination rules
pub const SmugglingError = error{
    /// Both Content-Length and Transfer-Encoding headers present.
    DualFraming,
    /// Multiple Content-Length headers with different values.
    DuplicateContentLength,
    /// Content-Length value is not a valid non-negative integer.
    InvalidContentLength,
    /// Transfer-Encoding value is not exactly "chunked".
    NonChunkedTransferEncoding,
    /// Content-Length present when Transfer-Encoding: chunked also present.
    ContentLengthWithChunked,
    /// Obsolete line folding detected (line starting with space/tab).
    ObsFoldInHeaders,
    /// Null byte (0x00) in header value.
    NullInHeaders,
    /// Bare LF or invalid characters in request line.
    BadRequestLine,
};

/// Case-insensitive header name comparison.
fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

/// Validate Content-Length value string.
/// Must be a non-negative integer with no leading zeros (except "0" itself),
/// no whitespace, no sign characters.
// Reference: Kettle 2025 — leading zeros in CL cause parser disagreements
fn parseContentLength(value: []const u8) SmugglingError!u64 {
    if (value.len == 0) return error.InvalidContentLength;
    // Reject leading zeros (except bare "0")
    if (value.len > 1 and value[0] == '0') return error.InvalidContentLength;
    for (value) |c| {
        if (c < '0' or c > '9') return error.InvalidContentLength;
    }
    return std.fmt.parseInt(u64, value, 10) catch error.InvalidContentLength;
}

/// Validate Transfer-Encoding value.
/// Only bare "chunked" is accepted. Anything else is rejected.
fn checkTransferEncoding(value: []const u8) SmugglingError!void {
    if (!eqlIgnoreCase(value, "chunked")) return error.NonChunkedTransferEncoding;
}

/// Validate a parsed request's body framing and reject any ambiguity.
///
/// Rules (strict mode, following Kettle 2025 recommendations):
// Reference: src/net/REFERENCES.md — Kettle 2025 strict CL/TE/CL+TE rejection rules
/// 1. Scan all headers for null bytes and obs-fold.
/// 2. If both CL and TE present → DualFraming.
/// 3. If multiple CL with different values → DuplicateContentLength.
/// 4. If CL is non-numeric or has leading zeros → InvalidContentLength.
/// 5. If TE is not exactly "chunked" → NonChunkedTransferEncoding.
/// 6. If method is GET/HEAD/DELETE/CONNECT → .none (no body expected).
/// 7. Return the determined framing.
pub fn validate(headers: []const Header, method: Method) SmugglingError!BodyFraming {
    var cl_value: ?[]const u8 = null;
    var has_te = false;
    var has_cl = false;

    for (headers) |h| {
        validateHeaderValue(h.value) catch |e| return e;

        if (eqlIgnoreCase(h.name, "content-length")) {
            if (has_cl) {
                // Duplicate CL — reject if values differ
                if (!mem.eql(u8, cl_value.?, h.value)) return error.DuplicateContentLength;
            } else {
                _ = parseContentLength(h.value) catch |e| return e;
                cl_value = h.value;
                has_cl = true;
            }
        } else if (eqlIgnoreCase(h.name, "transfer-encoding")) {
            checkTransferEncoding(h.value) catch |e| return e;
            has_te = true;
        }
    }

    // Both CL and TE present → reject (the classic CL.TE attack vector)
    if (has_cl and has_te) return error.DualFraming;

    // Methods that do not carry a body
    switch (method) {
        .GET, .HEAD, .DELETE, .CONNECT => return .none,
        else => {},
    }

    if (has_te) return .chunked;
    if (has_cl) return .content_length;
    return .none;
}

/// Validate a request line for characters that enable desync attacks.
// Reference: src/net/REFERENCES.md — Kettle 2025 request line validation (null bytes, bare LF, obs-fold)
pub fn validateRequestLine(line: []const u8) SmugglingError!void {
    var prev_cr = false;
    for (line) |c| {
        if (c == 0) return error.BadRequestLine;
        if (c == '\n' and !prev_cr) return error.BadRequestLine;
        prev_cr = (c == '\r');
    }
    // Obs-fold: line starting with space or tab
    if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) return error.ObsFoldInHeaders;
}

/// Validate a header value for smuggling injection vectors.
pub fn validateHeaderValue(value: []const u8) SmugglingError!void {
    for (value) |c| {
        if (c == 0) return error.NullInHeaders;
    }
    // Obs-fold: value starting with space or tab after a line break
    // (In practice this catches values that themselves contain obs-fold markers)
    if (value.len > 0 and (value[0] == ' ' or value[0] == '\t')) return error.ObsFoldInHeaders;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "smuggling accept no body" {
    // GET with no CL or TE → .none
    const headers = [_]Header{.{ .name = "Host", .value = "example.com" }};
    const framing = try validate(&headers, .GET);
    try testing.expectEqual(BodyFraming.none, framing);
}

test "smuggling accept valid cl" {
    // POST with CL: 42 → .content_length
    const headers = [_]Header{.{ .name = "Content-Length", .value = "42" }};
    const framing = try validate(&headers, .POST);
    try testing.expectEqual(BodyFraming.content_length, framing);
}

test "smuggling accept valid te chunked" {
    // POST with TE: chunked → .chunked
    const headers = [_]Header{.{ .name = "Transfer-Encoding", .value = "chunked" }};
    const framing = try validate(&headers, .POST);
    try testing.expectEqual(BodyFraming.chunked, framing);
}

test "smuggling reject cl and te" {
    // Both CL and TE present → DualFraming
    const headers = [_]Header{
        .{ .name = "Content-Length", .value = "10" },
        .{ .name = "Transfer-Encoding", .value = "chunked" },
    };
    try testing.expectError(error.DualFraming, validate(&headers, .POST));
}

test "smuggling reject duplicate cl" {
    // Multiple CL with different values → DuplicateContentLength
    const headers = [_]Header{
        .{ .name = "Content-Length", .value = "10" },
        .{ .name = "Content-Length", .value = "20" },
    };
    try testing.expectError(error.DuplicateContentLength, validate(&headers, .POST));
}

test "smuggling accept duplicate cl same value" {
    // Multiple CL with identical values → allowed
    const headers = [_]Header{
        .{ .name = "Content-Length", .value = "10" },
        .{ .name = "Content-Length", .value = "10" },
    };
    const framing = try validate(&headers, .POST);
    try testing.expectEqual(BodyFraming.content_length, framing);
}

test "smuggling reject non numeric cl" {
    const headers = [_]Header{.{ .name = "Content-Length", .value = "abc" }};
    try testing.expectError(error.InvalidContentLength, validate(&headers, .POST));
}

test "smuggling reject negative cl" {
    const headers = [_]Header{.{ .name = "Content-Length", .value = "-1" }};
    try testing.expectError(error.InvalidContentLength, validate(&headers, .POST));
}

test "smuggling reject cl leading zeros" {
    // Kettle 2025: leading zeros cause parser disagreements
    const headers = [_]Header{.{ .name = "Content-Length", .value = "010" }};
    try testing.expectError(error.InvalidContentLength, validate(&headers, .POST));
}

test "smuggling reject non canonical te" {
    // TE: "gzip, chunked" → NonChunkedTransferEncoding
    const headers = [_]Header{.{ .name = "Transfer-Encoding", .value = "gzip, chunked" }};
    try testing.expectError(error.NonChunkedTransferEncoding, validate(&headers, .POST));
}

test "smuggling validate content length" {
    // Zero is valid
    try testing.expectEqual(@as(u64, 0), try parseContentLength("0"));
    // Normal value
    try testing.expectEqual(@as(u64, 12345), try parseContentLength("12345"));
    // Reject empty
    try testing.expectError(error.InvalidContentLength, parseContentLength(""));
    // Reject leading zeros
    try testing.expectError(error.InvalidContentLength, parseContentLength("007"));
    // Reject sign
    try testing.expectError(error.InvalidContentLength, parseContentLength("+5"));
    // Reject spaces
    try testing.expectError(error.InvalidContentLength, parseContentLength("5 "));
}

test "smuggling validate request line null bytes" {
    try testing.expectError(error.BadRequestLine, validateRequestLine("GET /\x00 HTTP/1.1"));
}

test "smuggling validate request line bare lf" {
    // Bare LF without preceding CR
    try testing.expectError(error.BadRequestLine, validateRequestLine("GET / HTTP/1.1\n"));
}

test "smuggling reject null in header value" {
    const headers = [_]Header{.{ .name = "X-Foo", .value = "bar\x00baz" }};
    try testing.expectError(error.NullInHeaders, validate(&headers, .POST));
}

test "smuggling reject obs fold in headers" {
    // Value starting with space (obs-fold)
    const headers = [_]Header{.{ .name = "X-Foo", .value = " continued" }};
    try testing.expectError(error.ObsFoldInHeaders, validate(&headers, .POST));
}

test "smuggling get with cl returns none" {
    // GET with CL present — method wins, body not expected
    const headers = [_]Header{.{ .name = "Content-Length", .value = "5" }};
    const framing = try validate(&headers, .GET);
    try testing.expectEqual(BodyFraming.none, framing);
}

test "smuggling head with te returns none" {
    // HEAD with TE present — method wins
    const headers = [_]Header{.{ .name = "Transfer-Encoding", .value = "chunked" }};
    const framing = try validate(&headers, .HEAD);
    try testing.expectEqual(BodyFraming.none, framing);
}

test "smuggling valid request line" {
    // Valid request line with proper CRLF
    try validateRequestLine("GET / HTTP/1.1\r\n");
}

test "smuggling reject te with spaces" {
    // " chunked" (leading space) → NonChunkedTransferEncoding
    const headers = [_]Header{.{ .name = "Transfer-Encoding", .value = " chunked" }};
    try testing.expectError(error.ObsFoldInHeaders, validate(&headers, .POST));
}
