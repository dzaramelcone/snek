//! PostgreSQL authentication: SCRAM-SHA-256, md5, trust.
//!
//! SCRAM-SHA-256: full SASL handshake with PBKDF2 + HMAC-SHA-256.
//! md5: md5(md5(password + user) + salt).
//! trust: no authentication required.
//!
//! Generic-over-IO.
//!
//! Sources:
//!   - SCRAM-SHA-256 flow: RFC 7677 (SCRAM-SHA-256), RFC 5802 (SCRAM).
//!     PostgreSQL SASL authentication docs. See src/db/REFERENCES.md.
//!   - MD5 auth: PostgreSQL legacy md5 scheme — md5(md5(password + user) + salt).
//!   - Generic-over-IO: TigerBeetle pattern.

const std = @import("std");
const wire = @import("wire.zig");

// ─── Auth method enum ────────────────────────────────────────────────

pub const AuthMethod = enum {
    trust,
    md5,
    scram_sha_256,
};

// ─── SCRAM-SHA-256 state machine ─────────────────────────────────────
// Source: RFC 5802 / RFC 7677 — client-first → server-first → client-final → server-final.
// See src/db/REFERENCES.md for PostgreSQL-specific SASL integration details.

pub const ScramState = enum {
    initial,
    server_first_received,
    server_final_received,
    complete,
};

pub fn ScramSha256AuthType(comptime IO: type) type {
    return struct {
        const Self = @This();

        io: *IO,
        state: ScramState,
        client_nonce: [24]u8,
        server_nonce: []const u8,
        salt: []const u8,
        iterations: u32,
        auth_message: []const u8,

        /// Begin SCRAM handshake: generate client-first-message,
        /// send SaslInitialResponse.
        pub fn clientFirstMessage(self: *Self, user: []const u8) ![]const u8 {
            _ = .{ self, user };
            return undefined;
        }

        /// Process server-first-message: extract salt, iteration count, server nonce.
        /// Compute PBKDF2(password, salt, iterations) → SaltedPassword.
        /// Send SaslResponse with client-final-message.
        pub fn handleServerFirst(self: *Self, server_first: []const u8, password: []const u8) ![]const u8 {
            _ = .{ self, server_first, password };
            return undefined;
        }

        /// Process server-final-message: verify server signature.
        pub fn handleServerFinal(self: *Self, server_final: []const u8) !void {
            _ = .{ self, server_final };
        }

        /// Compute HMAC-SHA-256.
        pub fn hmacSha256(key: []const u8, data: []const u8) [32]u8 {
            _ = .{ key, data };
            return undefined;
        }

        /// Compute PBKDF2 with HMAC-SHA-256.
        pub fn pbkdf2(password: []const u8, salt: []const u8, iterations: u32) [32]u8 {
            _ = .{ password, salt, iterations };
            return undefined;
        }
    };
}

// ─── MD5 authentication ──────────────────────────────────────────────

pub fn Md5AuthType(comptime IO: type) type {
    return struct {
        const Self = @This();

        io: *IO,

        /// Compute md5(md5(password + user) + salt) and send PasswordMessage.
        pub fn authenticate(self: *Self, user: []const u8, password: []const u8, salt: [4]u8) !void {
            _ = .{ self, user, password, salt };
        }

        /// Compute md5 hex digest.
        pub fn md5Hex(data: []const u8) [32]u8 {
            _ = .{data};
            return undefined;
        }
    };
}

// ─── Trust authentication ────────────────────────────────────────────

pub fn TrustAuthType(comptime IO: type) type {
    return struct {
        const Self = @This();

        io: *IO,

        /// No-op: trust auth requires no credentials.
        pub fn authenticate(self: *Self) !void {
            _ = .{self};
        }
    };
}

// ─── Auth dispatcher ─────────────────────────────────────────────────

pub fn AuthenticatorType(comptime IO: type) type {
    return struct {
        const Self = @This();

        io: *IO,

        /// Dispatch to the appropriate auth handler based on the server's
        /// AuthenticationRequest message.
        pub fn run(self: *Self, auth_type: wire.AuthType, user: []const u8, password: []const u8) !void {
            _ = .{ self, auth_type, user, password };
        }
    };
}

test "scram sha256 client first message" {}

test "scram sha256 server first handling" {}

test "scram sha256 server final verification" {}

test "scram sha256 pbkdf2" {}

test "scram sha256 hmac" {}

test "scram sha256 full handshake" {}

test "md5 auth hash computation" {}

test "md5 auth authenticate" {}

test "trust auth no-op" {}

test "auth dispatcher scram" {}

test "auth dispatcher md5" {}

test "auth dispatcher trust" {}
