//! Zig-native JSON parser — thin wrapper over std.json with convenience helpers.
//!
//! Keeps std.json as the engine. No custom tokenizer, no SIMD (deferred).
//! Provides typed field accessors for ergonomic use in snek handlers.
//!
//! Source: std.json (Zig 0.15)

const std = @import("std");

/// Re-export std.json.Value as the canonical value type.
pub const Value = std.json.Value;
pub const ObjectMap = std.json.ObjectMap;
pub const Array = std.json.Array;
pub const Parsed = std.json.Parsed;

/// Parse a JSON string into a Value tree.
/// All allocations go through the returned Parsed's arena — call deinit() when done.
pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Parsed(Value) {
    return std.json.parseFromSlice(Value, allocator, input, .{});
}

// ---------------------------------------------------------------------------
// Convenience field accessors — pull typed values from an object by key.
// Return null if the key is missing or the value is the wrong type.
// ---------------------------------------------------------------------------

pub fn getString(value: Value, key: []const u8) ?[]const u8 {
    const obj = asObject(value) orelse return null;
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

pub fn getInt(value: Value, key: []const u8) ?i64 {
    const obj = asObject(value) orelse return null;
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

pub fn getFloat(value: Value, key: []const u8) ?f64 {
    const obj = asObject(value) orelse return null;
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .float => |f| f,
        else => null,
    };
}

pub fn getBool(value: Value, key: []const u8) ?bool {
    const obj = asObject(value) orelse return null;
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

pub fn getArray(value: Value, key: []const u8) ?[]const Value {
    const obj = asObject(value) orelse return null;
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .array => |a| a.items,
        else => null,
    };
}

pub fn getObject(value: Value, key: []const u8) ?Value {
    const obj = asObject(value) orelse return null;
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .object => v,
        else => null,
    };
}

pub fn isNull(value: Value, key: []const u8) bool {
    const obj = asObject(value) orelse return false;
    const v = obj.get(key) orelse return false;
    return v == .null;
}

/// Extract the ObjectMap from a Value, or null if not an object.
fn asObject(value: Value) ?ObjectMap {
    return switch (value) {
        .object => |o| o,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parse simple object" {
    const allocator = std.testing.allocator;
    const parsed = try parse(allocator,
        \\{"name":"snek","version":1}
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("snek", getString(parsed.value, "name").?);
    try std.testing.expectEqual(@as(i64, 1), getInt(parsed.value, "version").?);
}

test "parse nested object" {
    const allocator = std.testing.allocator;
    const parsed = try parse(allocator,
        \\{"user":{"id":1,"name":"dzara"}}
    );
    defer parsed.deinit();

    const user = getObject(parsed.value, "user").?;
    try std.testing.expectEqual(@as(i64, 1), getInt(user, "id").?);
    try std.testing.expectEqualStrings("dzara", getString(user, "name").?);
}

test "parse array" {
    const allocator = std.testing.allocator;
    const parsed = try parse(allocator, "[1,2,3]");
    defer parsed.deinit();

    const items = parsed.value.array.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(@as(i64, 1), items[0].integer);
    try std.testing.expectEqual(@as(i64, 2), items[1].integer);
    try std.testing.expectEqual(@as(i64, 3), items[2].integer);
}

test "parse null and bool" {
    const allocator = std.testing.allocator;
    const parsed = try parse(allocator,
        \\{"active":true,"deleted":null}
    );
    defer parsed.deinit();

    try std.testing.expect(getBool(parsed.value, "active").?);
    try std.testing.expect(isNull(parsed.value, "deleted"));
}

test "get helpers return null on wrong type" {
    const allocator = std.testing.allocator;
    const parsed = try parse(allocator,
        \\{"name":"snek","version":1,"active":true}
    );
    defer parsed.deinit();

    // getString on an integer field -> null
    try std.testing.expect(getString(parsed.value, "version") == null);
    // getInt on a string field -> null
    try std.testing.expect(getInt(parsed.value, "name") == null);
    // getBool on a string field -> null
    try std.testing.expect(getBool(parsed.value, "name") == null);
    // missing key -> null
    try std.testing.expect(getString(parsed.value, "nope") == null);
    // helpers on non-object value -> null
    const arr_parsed = try parse(allocator, "[1,2]");
    defer arr_parsed.deinit();
    try std.testing.expect(getString(arr_parsed.value, "x") == null);
}

test "reject invalid JSON" {
    const allocator = std.testing.allocator;

    // truncated
    const r1 = parse(allocator, "{\"a\":");
    try std.testing.expect(r1 == error.UnexpectedEndOfInput);

    // missing quotes
    const r2 = parse(allocator, "{a: 1}");
    try std.testing.expectError(error.SyntaxError, r2);

    // trailing comma (strict mode)
    const r3 = parse(allocator, "{\"a\":1,}");
    try std.testing.expectError(error.SyntaxError, r3);
}
