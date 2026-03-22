//! Security headers: OWASP-recommended defaults, overridable in snek.toml.
//!
//! Pre-rendered at startup, injected into every response with zero per-request cost.
//! Includes: HSTS, X-Content-Type-Options, X-Frame-Options, CSP, Referrer-Policy,
//! Permissions-Policy.
//!
//! Source: OWASP recommended headers (src/security/REFERENCES.md).

const std = @import("std");

pub const FrameOptions = enum {
    deny,
    sameorigin,
};

/// Source: OWASP secure headers project — recommended defaults for all web applications
/// (src/security/REFERENCES.md).
pub const SecurityHeaders = struct {
    /// HSTS max-age in seconds (default: 63072000 = 2 years).
    hsts_max_age: u32,
    /// Include subdomains in HSTS.
    hsts_include_subdomains: bool,
    /// HSTS preload directive.
    hsts_preload: bool,
    /// X-Frame-Options value.
    frame_options: FrameOptions,
    /// X-Content-Type-Options: nosniff (always true by default).
    content_type_nosniff: bool,
    /// Content-Security-Policy value (null = omit header).
    csp: ?[]const u8,
    /// Referrer-Policy value (default: "strict-origin-when-cross-origin").
    referrer_policy: []const u8,
    /// Permissions-Policy value (default: restrictive).
    permissions_policy: ?[]const u8,

    pub fn defaults() SecurityHeaders {
        return .{
            .hsts_max_age = 63_072_000,
            .hsts_include_subdomains = true,
            .hsts_preload = false,
            .frame_options = .deny,
            .content_type_nosniff = true,
            .csp = null,
            .referrer_policy = "strict-origin-when-cross-origin",
            .permissions_policy = null,
        };
    }

    /// Build SecurityHeaders from snek.toml config values.
    pub fn fromConfig(config: anytype) SecurityHeaders {
        _ = .{config};
        return undefined;
    }
};

/// Pre-rendered security headers, built once at startup.
/// All header values are pre-formatted byte slices.
pub const PreRenderedSecurityHeaders = struct {
    /// Pre-built Strict-Transport-Security value.
    hsts: ?[]const u8,
    /// Pre-built X-Frame-Options value.
    frame_options: []const u8,
    /// "nosniff" if enabled.
    content_type_options: ?[]const u8,
    /// Pre-built CSP value.
    csp: ?[]const u8,
    /// Pre-built Referrer-Policy value.
    referrer_policy: []const u8,
    /// Pre-built Permissions-Policy value.
    permissions_policy: ?[]const u8,

    /// Build pre-rendered headers from SecurityHeaders at startup.
    pub fn fromHeaders(allocator: std.mem.Allocator, sh: SecurityHeaders) !PreRenderedSecurityHeaders {
        _ = .{ allocator, sh };
        return undefined;
    }

    /// Inject all security headers into response. Zero allocation per request.
    pub fn inject(self: *const PreRenderedSecurityHeaders, headers: *ResponseHeaders) void {
        _ = .{ self, headers };
    }
};

/// Opaque response header writer — subsystems inject into this.
pub const ResponseHeaders = struct {
    buf: [*]u8,
    len: usize,
    cap: usize,
};

test "inject security headers" {}

test "hsts header" {}

test "hsts include subdomains" {}

test "hsts preload" {}

test "content type nosniff" {}

test "frame options deny" {}

test "frame options sameorigin" {}

test "csp header" {}

test "referrer policy" {}

test "permissions policy" {}

test "security headers from config" {}

test "security headers defaults" {}
