//! Request tracing: ULID request IDs and W3C traceparent propagation.
//!
//! RequestId: ULID (time-sortable, lexicographically ordered, unique per request).
//! TraceContext: parse/propagate W3C traceparent header (version-traceid-parentid-flags).
//!
//! Sources:
//!   - ULID for request IDs — time-sortable, lexicographic ordering
//!     (https://github.com/ulid/spec)
//!   - W3C Trace Context spec for traceparent propagation
//!     (https://www.w3.org/TR/trace-context/)

const std = @import("std");

/// ULID-based request ID (128 bits: 48-bit timestamp + 80-bit random).
/// Source: ULID spec — time-sortable, Crockford Base32 encoded.
pub const RequestId = struct {
    bytes: [16]u8,

    /// Generate a new ULID request ID using current time + random.
    pub fn generate() RequestId {
        return undefined;
    }

    /// Encode as 26-character Crockford Base32 string.
    pub fn encode(self: *const RequestId, buf: *[26]u8) void {
        _ = .{ self, buf };
    }

    /// Decode from 26-character Crockford Base32 string.
    pub fn decode(s: *const [26]u8) !RequestId {
        _ = .{s};
        return undefined;
    }

    /// Extract millisecond timestamp from the ULID.
    pub fn timestamp(self: *const RequestId) i64 {
        _ = .{self};
        return undefined;
    }
};

/// W3C Trace Context (traceparent header).
/// Format: "version-traceid-parentid-traceflags"
/// Example: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
/// Source: W3C Trace Context spec (https://www.w3.org/TR/trace-context/).
pub const TraceContext = struct {
    version: u8,
    trace_id: [16]u8,
    parent_id: [8]u8,
    flags: u8,

    /// Parse W3C traceparent header value.
    pub fn fromHeader(header: []const u8) !TraceContext {
        _ = .{header};
        return undefined;
    }

    /// Serialize to W3C traceparent header value (55 bytes).
    pub fn toHeader(self: *const TraceContext, buf: *[55]u8) void {
        _ = .{ self, buf };
    }

    /// Create a new child span context (same trace_id, new parent_id).
    pub fn child(self: *const TraceContext) TraceContext {
        _ = .{self};
        return undefined;
    }

    /// Whether the sampled flag is set.
    pub fn isSampled(self: *const TraceContext) bool {
        _ = .{self};
        return undefined;
    }
};

test "generate ULID" {}

test "ULID encode decode roundtrip" {}

test "ULID timestamp extraction" {}

test "parse traceparent" {}

test "traceparent to header" {}

test "propagate trace" {}

test "child span context" {}

test "invalid traceparent header" {}

test "sampled flag" {}
