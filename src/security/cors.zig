//! CORS handling with pre-rendered headers at startup.
//!
//! Headers are compiled once from snek.toml [cors] config and injected
//! with zero overhead per request. No per-request allocation.
//!
//! Source: TurboAPI pre-rendered headers at startup — 0% overhead vs 24% for
//! Python middleware (src/http/REFERENCES_middleware.md).

const std = @import("std");

pub const CorsConfig = struct {
    allowed_origins: []const []const u8,
    allowed_methods: []const []const u8,
    allowed_headers: []const []const u8,
    expose_headers: []const []const u8,
    allow_credentials: bool,
    max_age: u32,

    pub fn defaults() CorsConfig {
        return .{
            .allowed_origins = &.{"*"},
            .allowed_methods = &.{ "GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS" },
            .allowed_headers = &.{"*"},
            .expose_headers = &.{},
            .allow_credentials = false,
            .max_age = 86400,
        };
    }
};

/// Pre-rendered CORS headers, built once at startup from CorsConfig.
/// All header values are pre-formatted byte slices — no formatting at request time.
/// Source: TurboAPI — pre-render all CORS header values at startup, inject as byte
/// slices per request with zero allocation (src/http/REFERENCES_middleware.md).
pub const PreRenderedCors = struct {
    /// Pre-built "Access-Control-Allow-Methods" value.
    allow_methods: []const u8,
    /// Pre-built "Access-Control-Allow-Headers" value.
    allow_headers: []const u8,
    /// Pre-built "Access-Control-Expose-Headers" value.
    expose_headers: []const u8,
    /// Pre-built "Access-Control-Max-Age" value.
    max_age: []const u8,
    /// Whether to include Access-Control-Allow-Credentials: true.
    allow_credentials: bool,
    /// Whether wildcard origin is configured (skip origin matching).
    wildcard_origin: bool,
    /// Allowed origins for non-wildcard matching.
    allowed_origins: []const []const u8,

    /// Build pre-rendered headers from CorsConfig at startup.
    pub fn fromConfig(allocator: std.mem.Allocator, config: CorsConfig) !PreRenderedCors {
        _ = .{ allocator, config };
        return undefined;
    }

    /// Handle OPTIONS preflight request. Returns pre-built response headers.
    /// Zero allocation per request.
    pub fn handlePreflight(self: *const PreRenderedCors, origin: []const u8) ?PreflightResponse {
        _ = .{ self, origin };
        return undefined;
    }

    /// Inject CORS headers into a normal (non-preflight) response.
    /// Zero allocation per request — copies pre-built slices.
    pub fn injectHeaders(self: *const PreRenderedCors, origin: []const u8, headers: *ResponseHeaders) void {
        _ = .{ self, origin, headers };
    }

    /// Check if the given origin is allowed by the CORS config.
    pub fn isAllowedOrigin(self: *const PreRenderedCors, origin: []const u8) bool {
        _ = .{ self, origin };
        return undefined;
    }
};

/// Pre-built preflight response (all values are pre-rendered slices).
pub const PreflightResponse = struct {
    allow_origin: []const u8,
    allow_methods: []const u8,
    allow_headers: []const u8,
    max_age: []const u8,
    allow_credentials: bool,
};

/// Opaque response header writer — subsystems inject into this.
pub const ResponseHeaders = struct {
    buf: [*]u8,
    len: usize,
    cap: usize,
};

test "cors pre-render from config" {}

test "cors handle preflight" {}

test "cors inject headers" {}

test "cors allowed origin check" {}

test "cors wildcard origin" {}

test "cors credentials handling" {}

test "cors zero allocation per request" {}
