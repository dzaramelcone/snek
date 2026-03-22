//! Cookie parsing, Set-Cookie serialization, and HMAC-SHA256 signing.

const std = @import("std");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
};

/// Parse a Cookie header value ("name1=val1; name2=val2") into out buffer.
/// Returns the number of cookies parsed.
pub fn parseCookieHeader(header_value: []const u8, out: []Cookie) usize {
    var count: usize = 0;
    var iter = std.mem.splitSequence(u8, header_value, "; ");
    while (iter.next()) |pair| {
        if (count >= out.len) break;
        const trimmed = std.mem.trim(u8, pair, " ");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
            out[count] = .{
                .name = trimmed[0..eq],
                .value = trimmed[eq + 1 ..],
            };
        } else {
            out[count] = .{ .name = trimmed, .value = "" };
        }
        count += 1;
    }
    return count;
}

pub const SameSite = enum { strict, lax, none };

/// Set-Cookie builder with full attribute support.
pub const SetCookie = struct {
    name: []const u8,
    value: []const u8,
    max_age: ?i64 = null,
    path: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: ?SameSite = null,

    /// Serialize to a Set-Cookie header value. Returns bytes written.
    pub fn serialize(self: *const SetCookie, buf: []u8) usize {
        var pos: usize = 0;

        pos = appendSlice(buf, pos, self.name);
        pos = appendByte(buf, pos, '=');
        pos = appendSlice(buf, pos, self.value);

        if (self.path) |p| {
            pos = appendSlice(buf, pos, "; Path=");
            pos = appendSlice(buf, pos, p);
        }
        if (self.domain) |d| {
            pos = appendSlice(buf, pos, "; Domain=");
            pos = appendSlice(buf, pos, d);
        }
        if (self.max_age) |ma| {
            pos = appendSlice(buf, pos, "; Max-Age=");
            var num_buf: [20]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{ma}) catch return pos;
            pos = appendSlice(buf, pos, num_str);
        }
        if (self.secure) pos = appendSlice(buf, pos, "; Secure");
        if (self.http_only) pos = appendSlice(buf, pos, "; HttpOnly");
        if (self.same_site) |ss| {
            pos = appendSlice(buf, pos, "; SameSite=");
            pos = appendSlice(buf, pos, switch (ss) {
                .strict => "Strict",
                .lax => "Lax",
                .none => "None",
            });
        }
        return pos;
    }
};

fn appendSlice(buf: []u8, pos: usize, s: []const u8) usize {
    const end = pos + s.len;
    if (end > buf.len) return pos;
    @memcpy(buf[pos..end], s);
    return end;
}

fn appendByte(buf: []u8, pos: usize, b: u8) usize {
    if (pos >= buf.len) return pos;
    buf[pos] = b;
    return pos + 1;
}

/// HMAC-SHA256 cookie signing. Format: "value.hex(mac)".
pub fn sign(value: []const u8, key: []const u8, out: []u8) usize {
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, value, key);
    const hex = std.fmt.bytesToHex(mac, .lower);
    const total = value.len + 1 + hex.len;
    if (total > out.len) return 0;
    @memcpy(out[0..value.len], value);
    out[value.len] = '.';
    @memcpy(out[value.len + 1 ..][0..hex.len], &hex);
    return total;
}

/// Verify an HMAC-signed value. Returns the original value if valid, null if tampered.
pub fn verify(signed_value: []const u8, key: []const u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, signed_value, '.') orelse return null;
    const value = signed_value[0..dot];
    const sig_hex = signed_value[dot + 1 ..];
    if (sig_hex.len != HmacSha256.mac_length * 2) return null;

    var expected: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&expected, value, key);
    const expected_hex = std.fmt.bytesToHex(expected, .lower);

    if (!std.mem.eql(u8, sig_hex, &expected_hex)) return null;
    return value;
}

// ============================================================
// Tests
// ============================================================

test "parse cookie header" {
    var cookies: [8]Cookie = undefined;
    const n = parseCookieHeader("session=abc123", &cookies);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("session", cookies[0].name);
    try std.testing.expectEqualStrings("abc123", cookies[0].value);
}

test "parse multiple cookies" {
    var cookies: [8]Cookie = undefined;
    const n = parseCookieHeader("a=1; b=2; c=3", &cookies);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("a", cookies[0].name);
    try std.testing.expectEqualStrings("1", cookies[0].value);
    try std.testing.expectEqualStrings("b", cookies[1].name);
    try std.testing.expectEqualStrings("2", cookies[1].value);
    try std.testing.expectEqualStrings("c", cookies[2].name);
    try std.testing.expectEqualStrings("3", cookies[2].value);
}

test "set-cookie serialization with attributes" {
    const sc = SetCookie{
        .name = "session",
        .value = "tok",
        .path = "/",
        .domain = "example.com",
        .max_age = 3600,
        .secure = true,
        .http_only = true,
        .same_site = .strict,
    };
    var buf: [256]u8 = undefined;
    const n = sc.serialize(&buf);
    const out = buf[0..n];
    try std.testing.expect(std.mem.startsWith(u8, out, "session=tok"));
    try std.testing.expect(std.mem.indexOf(u8, out, "; Path=/") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "; Domain=example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "; Max-Age=3600") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "; Secure") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "; HttpOnly") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "; SameSite=Strict") != null);
}

test "HMAC sign and verify" {
    const key = "secret-key-1234";
    const value = "user_session_data";
    var out: [256]u8 = undefined;
    const n = sign(value, key, &out);
    try std.testing.expect(n > 0);
    const signed = out[0..n];
    // Verify succeeds and returns original value
    const recovered = verify(signed, key);
    try std.testing.expect(recovered != null);
    try std.testing.expectEqualStrings(value, recovered.?);
}

test "HMAC verify rejects tampered value" {
    const key = "secret-key";
    var out: [256]u8 = undefined;
    const n = sign("hello", key, &out);
    // Tamper with the value portion
    out[0] = 'X';
    try std.testing.expect(verify(out[0..n], key) == null);
    // Wrong key
    const n2 = sign("hello", key, &out);
    try std.testing.expect(verify(out[0..n2], "wrong-key") == null);
}
