//! io_uring-backed outbound HTTP client with per-host connection pooling.
//!
//! Generic-over-IO for simulation testing. Sensible defaults for timeouts,
//! redirect following, retry, and TLS verification.
//!
//! Sources:
//!   - First io_uring-backed HTTP client (src/serve/REFERENCES_client.md —
//!     no production client uses io_uring yet)
//!   - Go late-binding pattern for connection acquisition

const std = @import("std");

pub const ClientRequest = struct {
    method: Method,
    url: []const u8,
    headers: []const Header,
    body: ?[]const u8,
};

pub const ClientResponse = struct {
    status: u16,
    headers: []const Header,
    body: []const u8,

    /// Parse the response body as JSON.
    pub fn json(self: *const ClientResponse) !@import("../json/parse.zig").JsonValue {
        _ = .{self};
        return undefined;
    }

    /// Return the response body as text.
    pub fn text(self: *const ClientResponse) []const u8 {
        return self.body;
    }
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
};

/// Timeout layering: connect, TLS, first byte, total.
pub const TimeoutConfig = struct {
    connect_timeout_ms: u32 = 5_000,
    tls_timeout_ms: u32 = 5_000,
    first_byte_timeout_ms: u32 = 10_000,
    total_timeout_ms: u32 = 30_000,
};

/// Retry configuration.
pub const RetryConfig = struct {
    max_retries: u8 = 3,
    retry_on_status: []const u16 = &.{ 502, 503, 504 },
    backoff_base_ms: u32 = 100,
    backoff_max_ms: u32 = 5_000,
};

pub const ClientConfig = struct {
    max_connections_per_host: u16 = 10,
    idle_timeout_ms: u32 = 90_000,
    timeouts: TimeoutConfig = .{},
    retry: RetryConfig = .{},
    max_redirects: u8 = 10,
    verify_tls: bool = true,
};

/// Per-host connection pool entry.
pub const PoolEntry = struct {
    fd: i32,
    host: []const u8,
    port: u16,
    is_tls: bool,
    created_at: i64,
    last_used_at: i64,
};

/// io_uring-backed HTTP client, Generic-over-IO for testability.
pub fn HttpClient(comptime IO: type) type {
    return struct {
        const Self = @This();

        io: *IO,
        config: ClientConfig,

        pub fn init(io: *IO, config: ClientConfig) Self {
            _ = .{ io, config };
            return undefined;
        }

        pub fn deinit(self: *Self) void {
            _ = .{self};
        }

        /// GET request.
        pub fn get(self: *Self, url: []const u8) !ClientResponse {
            _ = .{ self, url };
            return undefined;
        }

        /// POST request with body.
        pub fn post(self: *Self, url: []const u8, body: []const u8) !ClientResponse {
            _ = .{ self, url, body };
            return undefined;
        }

        /// PUT request with body.
        pub fn put(self: *Self, url: []const u8, body: []const u8) !ClientResponse {
            _ = .{ self, url, body };
            return undefined;
        }

        /// DELETE request.
        pub fn delete(self: *Self, url: []const u8) !ClientResponse {
            _ = .{ self, url };
            return undefined;
        }

        /// PATCH request with body.
        pub fn patch(self: *Self, url: []const u8, body: []const u8) !ClientResponse {
            _ = .{ self, url, body };
            return undefined;
        }

        /// Send a fully specified request.
        pub fn send(self: *Self, request: ClientRequest) !ClientResponse {
            _ = .{ self, request };
            return undefined;
        }

        /// Acquire a pooled connection for the given host, or create a new one.
        /// Source: Go late-binding pattern — defer connection acquisition until
        /// request is ready to send (src/serve/REFERENCES_client.md).
        fn acquireConnection(self: *Self, host: []const u8, port: u16, is_tls: bool) !PoolEntry {
            _ = .{ self, host, port, is_tls };
            return undefined;
        }

        /// Return a connection to the per-host pool.
        fn releaseConnection(self: *Self, entry: *PoolEntry) void {
            _ = .{ self, entry };
        }

        /// Follow redirects up to max_redirects.
        fn followRedirects(self: *Self, response: ClientResponse, remaining: u8) !ClientResponse {
            _ = .{ self, response, remaining };
            return undefined;
        }

        /// Retry a failed request with backoff.
        fn retryWithBackoff(self: *Self, request: ClientRequest, attempt: u8) !ClientResponse {
            _ = .{ self, request, attempt };
            return undefined;
        }
    };
}

test "GET request" {}

test "connection pool reuse" {}

test "timeout handling" {}

test "redirect following" {}

test "POST with body" {}

test "retry on 503" {}

test "TLS verification" {}
