//! Typed command wrappers for Redis operations.
//! Each function sends a command via Client and returns a typed result.

const std = @import("std");
const connection = @import("connection.zig");
const protocol = @import("protocol.zig");

const Client = connection.Client;

/// GET key -- returns the value or null if the key doesn't exist.
/// Caller must call .deinit() on the returned Response when the value is no longer needed.
pub fn get(client: *Client, key: []const u8) !struct { value: ?[]const u8, response: connection.Response } {
    const args = [_][]const u8{ "GET", key };
    var resp = try client.command(&args);
    return switch (resp.value) {
        .bulk_string => |s| .{ .value = s, .response = resp },
        .null_value => .{ .value = null, .response = resp },
        .error_msg => {
            resp.deinit();
            return error.RedisError;
        },
        else => {
            resp.deinit();
            return error.UnexpectedResponse;
        },
    };
}

/// SET key value -- sets the key to the given value.
pub fn set(client: *Client, key: []const u8, value: []const u8) !void {
    const args = [_][]const u8{ "SET", key, value };
    var resp = try client.command(&args);
    defer resp.deinit();
    switch (resp.value) {
        .simple_string => return, // +OK
        .error_msg => return error.RedisError,
        else => return error.UnexpectedResponse,
    }
}

/// DEL key -- deletes the key. Returns the number of keys deleted (0 or 1).
pub fn del(client: *Client, key: []const u8) !i64 {
    const args = [_][]const u8{ "DEL", key };
    var resp = try client.command(&args);
    defer resp.deinit();
    switch (resp.value) {
        .integer => |n| return n,
        .error_msg => return error.RedisError,
        else => return error.UnexpectedResponse,
    }
}

/// PING -- returns "PONG" (or the echoed message).
/// Caller must call .deinit() on the returned Response when the value is no longer needed.
pub fn ping(client: *Client) !struct { value: []const u8, response: connection.Response } {
    const args = [_][]const u8{"PING"};
    var resp = try client.command(&args);
    return switch (resp.value) {
        .simple_string => |s| .{ .value = s, .response = resp },
        .error_msg => {
            resp.deinit();
            return error.RedisError;
        },
        else => {
            resp.deinit();
            return error.UnexpectedResponse;
        },
    };
}

// ============================================================================
// Tests -- unit tests for command building (no Redis needed)
// ============================================================================

test "GET command encodes correctly" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "GET", "mykey" };
    const encoded = try protocol.encode(allocator, &args);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("*2\r\n$3\r\nGET\r\n$5\r\nmykey\r\n", encoded);
}

test "SET command encodes correctly" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "SET", "mykey", "myval" };
    const encoded = try protocol.encode(allocator, &args);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("*3\r\n$3\r\nSET\r\n$5\r\nmykey\r\n$5\r\nmyval\r\n", encoded);
}

test "DEL command encodes correctly" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "DEL", "mykey" };
    const encoded = try protocol.encode(allocator, &args);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("*2\r\n$3\r\nDEL\r\n$5\r\nmykey\r\n", encoded);
}

test "PING command encodes correctly" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{"PING"};
    const encoded = try protocol.encode(allocator, &args);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("*1\r\n$4\r\nPING\r\n", encoded);
}

// ============================================================================
// Integration tests -- gated on Redis being available
// ============================================================================

test "ping via typed command" {
    const allocator = std.testing.allocator;
    var client = Client.connect(allocator, "127.0.0.1", 6379) catch |err| {
        if (err == error.ConnectionRefused) return error.SkipZigTest;
        return err;
    };
    defer client.close();

    var result = try ping(&client);
    defer result.response.deinit();
    try std.testing.expectEqualStrings("PONG", result.value);
}

test "set and get via typed commands" {
    const allocator = std.testing.allocator;
    var client = Client.connect(allocator, "127.0.0.1", 6379) catch |err| {
        if (err == error.ConnectionRefused) return error.SkipZigTest;
        return err;
    };
    defer client.close();

    try set(&client, "snek:cmd:test", "typed_value");

    var result = try get(&client, "snek:cmd:test");
    defer result.response.deinit();
    try std.testing.expectEqualStrings("typed_value", result.value.?);

    const deleted = try del(&client, "snek:cmd:test");
    try std.testing.expectEqual(@as(i64, 1), deleted);
}

test "get nonexistent returns null via typed command" {
    const allocator = std.testing.allocator;
    var client = Client.connect(allocator, "127.0.0.1", 6379) catch |err| {
        if (err == error.ConnectionRefused) return error.SkipZigTest;
        return err;
    };
    defer client.close();

    var result = try get(&client, "snek:cmd:nonexistent_xyz");
    defer result.response.deinit();
    try std.testing.expect(result.value == null);
}

test "del nonexistent returns 0" {
    const allocator = std.testing.allocator;
    var client = Client.connect(allocator, "127.0.0.1", 6379) catch |err| {
        if (err == error.ConnectionRefused) return error.SkipZigTest;
        return err;
    };
    defer client.close();

    const deleted = try del(&client, "snek:cmd:nonexistent_xyz");
    try std.testing.expectEqual(@as(i64, 0), deleted);
}
