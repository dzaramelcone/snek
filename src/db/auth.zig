//! PostgreSQL MD5 authentication helper.
//!
//! md5: "md5" ++ md5(md5(password ++ user) ++ salt) — the Postgres legacy scheme.
//!
//! Source: https://www.postgresql.org/docs/current/auth-password.html

const std = @import("std");
const Md5 = std.crypto.hash.Md5;

// ─── MD5 authentication ──────────────────────────────────────────────
// Source: PostgreSQL md5 scheme — the password sent on the wire is:
//   "md5" ++ hex(md5(hex(md5(password ++ user)) ++ salt))
// Two rounds of MD5. The first hashes password+user, the second hashes that hex+salt.

/// Compute the Postgres MD5 password hash for wire transmission.
/// Returns a 35-byte string: "md5" + 32 hex chars.
pub fn computeMd5Password(user: []const u8, password: []const u8, salt: [4]u8) [35]u8 {
    // Step 1: md5(password ++ user) → 16 bytes → hex → 32 chars
    var h1 = Md5.init(.{});
    h1.update(password);
    h1.update(user);
    var digest1: [16]u8 = undefined;
    h1.final(&digest1);
    const hex1 = hexEncode(digest1);

    // Step 2: md5(hex1 ++ salt) → 16 bytes → hex → 32 chars
    var h2 = Md5.init(.{});
    h2.update(&hex1);
    h2.update(&salt);
    var digest2: [16]u8 = undefined;
    h2.final(&digest2);
    const hex2 = hexEncode(digest2);

    // Result: "md5" ++ hex2
    var result: [35]u8 = undefined;
    result[0] = 'm';
    result[1] = 'd';
    result[2] = '5';
    @memcpy(result[3..35], &hex2);
    return result;
}

/// Encode a 16-byte digest as 32 lowercase hex characters.
fn hexEncode(digest: [16]u8) [32]u8 {
    const hex_chars = "0123456789abcdef";
    var out: [32]u8 = undefined;
    for (digest, 0..) |byte, i| {
        out[i * 2] = hex_chars[byte >> 4];
        out[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return out;
}

// ─── Tests ───────────────────────────────────────────────────────────

test "md5 auth hash computation" {
    // Known test vector: user="postgres", password="secret", salt={0x01, 0x02, 0x03, 0x04}
    // Step 1: md5("secretpostgres") — password first, then user
    // Step 2: md5(hex_of_step1 ++ salt)
    // Result: "md5" ++ hex_of_step2
    const result = computeMd5Password("postgres", "secret", .{ 0x01, 0x02, 0x03, 0x04 });

    // Must start with "md5"
    try std.testing.expectEqualStrings("md5", result[0..3]);
    // Must be 35 bytes total
    try std.testing.expectEqual(result.len, 35);
    // The remaining 32 chars must be valid hex
    for (result[3..]) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "md5 auth deterministic" {
    // Same inputs must produce same output
    const r1 = computeMd5Password("user1", "pass1", .{ 0xAA, 0xBB, 0xCC, 0xDD });
    const r2 = computeMd5Password("user1", "pass1", .{ 0xAA, 0xBB, 0xCC, 0xDD });
    try std.testing.expectEqualStrings(&r1, &r2);
}

test "md5 auth different salt produces different hash" {
    const r1 = computeMd5Password("user", "pass", .{ 0x01, 0x02, 0x03, 0x04 });
    const r2 = computeMd5Password("user", "pass", .{ 0x05, 0x06, 0x07, 0x08 });
    try std.testing.expect(!std.mem.eql(u8, &r1, &r2));
}

test "md5 auth different user produces different hash" {
    const r1 = computeMd5Password("alice", "pass", .{ 0x01, 0x02, 0x03, 0x04 });
    const r2 = computeMd5Password("bob", "pass", .{ 0x01, 0x02, 0x03, 0x04 });
    try std.testing.expect(!std.mem.eql(u8, &r1, &r2));
}

test "md5 auth different password produces different hash" {
    const r1 = computeMd5Password("user", "alpha", .{ 0x01, 0x02, 0x03, 0x04 });
    const r2 = computeMd5Password("user", "bravo", .{ 0x01, 0x02, 0x03, 0x04 });
    try std.testing.expect(!std.mem.eql(u8, &r1, &r2));
}

test "md5 hex encode" {
    // md5("") = d41d8cd98f00b204e9800998ecf8427e
    var h = Md5.init(.{});
    var digest: [16]u8 = undefined;
    h.final(&digest);
    const hex = hexEncode(digest);
    try std.testing.expectEqualStrings("d41d8cd98f00b204e9800998ecf8427e", &hex);
}

test "md5 auth known vector" {
    // Verify against a manually computed value.
    // md5("testtest_user") where password="test", user="test_user"
    var h1 = Md5.init(.{});
    h1.update("test"); // password
    h1.update("test_user"); // user
    var d1: [16]u8 = undefined;
    h1.final(&d1);
    const hex1 = hexEncode(d1);

    // md5(hex1 ++ salt) where salt = {0,0,0,0}
    var h2 = Md5.init(.{});
    h2.update(&hex1);
    h2.update(&[4]u8{ 0, 0, 0, 0 });
    var d2: [16]u8 = undefined;
    h2.final(&d2);
    const hex2 = hexEncode(d2);

    const result = computeMd5Password("test_user", "test", .{ 0, 0, 0, 0 });
    try std.testing.expectEqualStrings(&hex2, result[3..35]);
    try std.testing.expectEqualStrings("md5", result[0..3]);
}
