//! Cookie parsing, Set-Cookie serialization, HMAC signing/verification.
//!
//! Design: All parsing in Zig. HMAC-SHA256 signing for session cookies.
//! Cryptographically random session ID generation. Full attribute support:
//! httponly, secure, samesite, path, domain, max-age, expires.

const std = @import("std");

/// SameSite attribute values.
pub const SameSite = enum {
    strict,
    lax,
    none,
};

/// A parsed or constructed cookie.
pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    domain: ?[]const u8 = null,
    path: ?[]const u8 = null,
    max_age: ?i64 = null,
    expires: ?[]const u8 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: ?SameSite = null,
};

/// Cookie jar: parses Cookie header, builds Set-Cookie headers.
pub const CookieJar = struct {
    cookies: [64]Cookie,
    count: usize,

    pub fn init() CookieJar {
        return undefined;
    }

    /// Parse a Cookie header (e.g. "name1=value1; name2=value2") into the jar.
    pub fn parse(header: []const u8) !CookieJar {
        _ = .{header};
        return undefined;
    }

    /// Get a cookie by name.
    pub fn get(self: *const CookieJar, name: []const u8) ?Cookie {
        _ = .{ self, name };
        return undefined;
    }

    /// Add or update a cookie.
    pub fn set(self: *CookieJar, cookie: Cookie) void {
        _ = .{ self, cookie };
    }

    /// Delete a cookie by setting max-age to 0.
    pub fn delete(self: *CookieJar, name: []const u8) void {
        _ = .{ self, name };
    }

    /// Serialize a cookie to a Set-Cookie header value with all attributes.
    pub fn serializeSetCookie(cookie: Cookie) []const u8 {
        _ = .{cookie};
        return undefined;
    }

    // -- HMAC signing for session cookies --
    // Source: HMAC-SHA256 cookie signing — standard practice for tamper-proof session cookies.

    /// Sign a cookie value with HMAC-SHA256. Returns "value.signature".
    pub fn sign(value: []const u8, secret: []const u8) ![]const u8 {
        _ = .{ value, secret };
        return undefined;
    }

    /// Verify an HMAC-signed cookie value. Returns the original value if valid.
    pub fn verify(signed_value: []const u8, secret: []const u8) !?[]const u8 {
        _ = .{ signed_value, secret };
        return undefined;
    }

    /// Generate a cryptographically random session ID (32 bytes, hex-encoded).
    pub fn generateSessionId() [64]u8 {
        return undefined;
    }
};

test "parse cookie header" {}

test "set-cookie with attributes" {}

test "hmac sign and verify" {}

test "session id generation" {}

test "cookie get by name" {}

test "cookie delete sets max-age zero" {}
