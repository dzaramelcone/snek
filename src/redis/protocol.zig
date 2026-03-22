//! RESP3 protocol (Redis Serialization Protocol) encoding and decoding.
//!
//! Implements the core wire format for Redis communication:
//! - Simple string: +OK\r\n
//! - Error: -ERR message\r\n
//! - Integer: :42\r\n
//! - Bulk string: $5\r\nhello\r\n
//! - Array: *2\r\n$3\r\nGET\r\n$3\r\nkey\r\n
//! - Null: _\r\n
//!
//! Source: Redis RESP3 spec (https://github.com/redis/redis-specifications/blob/master/protocol/RESP3.md).

const std = @import("std");

pub const RespValue = union(enum) {
    simple_string: []const u8,
    error_msg: []const u8,
    integer: i64,
    bulk_string: []const u8,
    array: []const RespValue,
    null_value,
};

/// Encode a command as a RESP array of bulk strings.
/// Caller owns the returned slice.
pub fn encode(allocator: std.mem.Allocator, args: []const []const u8) std.mem.Allocator.Error![]u8 {
    // Calculate total size needed.
    // *N\r\n + for each arg: $len\r\narg\r\n
    var size: usize = 0;
    size += 1; // '*'
    size += countDigits(args.len);
    size += 2; // \r\n

    for (args) |arg| {
        size += 1; // '$'
        size += countDigits(arg.len);
        size += 2; // \r\n
        size += arg.len;
        size += 2; // \r\n
    }

    const buf = try allocator.alloc(u8, size);
    var pos: usize = 0;

    buf[pos] = '*';
    pos += 1;
    pos += writeUsize(buf[pos..], args.len);
    buf[pos] = '\r';
    buf[pos + 1] = '\n';
    pos += 2;

    for (args) |arg| {
        buf[pos] = '$';
        pos += 1;
        pos += writeUsize(buf[pos..], arg.len);
        buf[pos] = '\r';
        buf[pos + 1] = '\n';
        pos += 2;
        @memcpy(buf[pos..][0..arg.len], arg);
        pos += arg.len;
        buf[pos] = '\r';
        buf[pos + 1] = '\n';
        pos += 2;
    }

    std.debug.assert(pos == size);
    return buf;
}

/// Decode a single RESP3 value from the data buffer.
/// Returns the decoded value and the number of bytes consumed.
/// Bulk string and simple string slices point into the input data buffer (zero-copy).
/// Array elements are allocated via the provided allocator; caller must free them.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) !struct { value: RespValue, consumed: usize } {
    if (data.len == 0) return error.Incomplete;

    const type_byte = data[0];
    const rest = data[1..];

    switch (type_byte) {
        '+' => {
            const line_end = findCrLf(rest) orelse return error.Incomplete;
            return .{
                .value = .{ .simple_string = rest[0..line_end] },
                .consumed = 1 + line_end + 2,
            };
        },
        '-' => {
            const line_end = findCrLf(rest) orelse return error.Incomplete;
            return .{
                .value = .{ .error_msg = rest[0..line_end] },
                .consumed = 1 + line_end + 2,
            };
        },
        ':' => {
            const line_end = findCrLf(rest) orelse return error.Incomplete;
            const num = std.fmt.parseInt(i64, rest[0..line_end], 10) catch
                return error.InvalidInteger;
            return .{
                .value = .{ .integer = num },
                .consumed = 1 + line_end + 2,
            };
        },
        '$' => {
            const line_end = findCrLf(rest) orelse return error.Incomplete;
            const len = std.fmt.parseInt(i64, rest[0..line_end], 10) catch
                return error.InvalidLength;
            if (len < 0) {
                // $-1\r\n is RESP2 null bulk string
                return .{
                    .value = .{ .null_value = {} },
                    .consumed = 1 + line_end + 2,
                };
            }
            const str_len: usize = @intCast(len);
            const str_start = line_end + 2; // skip past \r\n after length
            if (rest.len < str_start + str_len + 2) return error.Incomplete;
            return .{
                .value = .{ .bulk_string = rest[str_start..][0..str_len] },
                .consumed = 1 + str_start + str_len + 2,
            };
        },
        '*' => {
            const line_end = findCrLf(rest) orelse return error.Incomplete;
            const count = std.fmt.parseInt(i64, rest[0..line_end], 10) catch
                return error.InvalidLength;
            if (count < 0) {
                return .{
                    .value = .{ .null_value = {} },
                    .consumed = 1 + line_end + 2,
                };
            }
            const elem_count: usize = @intCast(count);
            const items = try allocator.alloc(RespValue, elem_count);
            var decoded_count: usize = 0;
            errdefer {
                for (0..decoded_count) |j| {
                    freeValue(allocator, items[j]);
                }
                allocator.free(items);
            }
            var total_consumed: usize = 1 + line_end + 2;

            for (0..elem_count) |i| {
                const result = try decode(allocator, data[total_consumed..]);
                items[i] = result.value;
                decoded_count += 1;
                total_consumed += result.consumed;
            }

            return .{
                .value = .{ .array = items },
                .consumed = total_consumed,
            };
        },
        '_' => {
            // Null: _\r\n
            if (rest.len < 2) return error.Incomplete;
            return .{
                .value = .{ .null_value = {} },
                .consumed = 3,
            };
        },
        else => return error.UnknownType,
    }
}

/// Free array elements allocated during decode.
pub fn freeValue(allocator: std.mem.Allocator, value: RespValue) void {
    switch (value) {
        .array => |items| {
            for (items) |item| {
                freeValue(allocator, item);
            }
            allocator.free(items);
        },
        else => {},
    }
}

// --- Internal helpers ---

fn findCrLf(data: []const u8) ?usize {
    if (data.len < 2) return null;
    for (0..data.len - 1) |i| {
        if (data[i] == '\r' and data[i + 1] == '\n') return i;
    }
    return null;
}

fn countDigits(n: usize) usize {
    if (n == 0) return 1;
    var count: usize = 0;
    var v = n;
    while (v > 0) : (v /= 10) {
        count += 1;
    }
    return count;
}

fn writeUsize(buf: []u8, n: usize) usize {
    const digits = countDigits(n);
    var v = n;
    var i: usize = digits;
    while (i > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }
    return digits;
}

// ============================================================================
// Tests
// ============================================================================

test "encode SET key val" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "SET", "key", "val" };
    const encoded = try encode(allocator, &args);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$3\r\nval\r\n", encoded);
}

test "encode GET key" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "GET", "mykey" };
    const encoded = try encode(allocator, &args);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("*2\r\n$3\r\nGET\r\n$5\r\nmykey\r\n", encoded);
}

test "encode PING (no args)" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{"PING"};
    const encoded = try encode(allocator, &args);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("*1\r\n$4\r\nPING\r\n", encoded);
}

test "decode simple string" {
    const allocator = std.testing.allocator;
    const result = try decode(allocator, "+OK\r\n");
    defer freeValue(allocator, result.value);
    try std.testing.expectEqualStrings("OK", result.value.simple_string);
    try std.testing.expectEqual(@as(usize, 5), result.consumed);
}

test "decode bulk string" {
    const allocator = std.testing.allocator;
    const result = try decode(allocator, "$5\r\nhello\r\n");
    defer freeValue(allocator, result.value);
    try std.testing.expectEqualStrings("hello", result.value.bulk_string);
    try std.testing.expectEqual(@as(usize, 11), result.consumed);
}

test "decode integer" {
    const allocator = std.testing.allocator;
    const result = try decode(allocator, ":42\r\n");
    defer freeValue(allocator, result.value);
    try std.testing.expectEqual(@as(i64, 42), result.value.integer);
    try std.testing.expectEqual(@as(usize, 5), result.consumed);
}

test "decode negative integer" {
    const allocator = std.testing.allocator;
    const result = try decode(allocator, ":-1\r\n");
    defer freeValue(allocator, result.value);
    try std.testing.expectEqual(@as(i64, -1), result.value.integer);
}

test "decode error message" {
    const allocator = std.testing.allocator;
    const result = try decode(allocator, "-ERR bad\r\n");
    defer freeValue(allocator, result.value);
    try std.testing.expectEqualStrings("ERR bad", result.value.error_msg);
}

test "decode null value" {
    const allocator = std.testing.allocator;
    const result = try decode(allocator, "_\r\n");
    defer freeValue(allocator, result.value);
    try std.testing.expectEqual(RespValue{ .null_value = {} }, result.value);
    try std.testing.expectEqual(@as(usize, 3), result.consumed);
}

test "decode RESP2 null bulk string" {
    const allocator = std.testing.allocator;
    const result = try decode(allocator, "$-1\r\n");
    defer freeValue(allocator, result.value);
    try std.testing.expectEqual(RespValue{ .null_value = {} }, result.value);
}

test "decode nested array" {
    const allocator = std.testing.allocator;
    // *2\r\n$3\r\nfoo\r\n*1\r\n:99\r\n
    // An array of [bulk_string("foo"), array([integer(99)])]
    const data = "*2\r\n$3\r\nfoo\r\n*1\r\n:99\r\n";
    const result = try decode(allocator, data);
    defer freeValue(allocator, result.value);

    const outer = result.value.array;
    try std.testing.expectEqual(@as(usize, 2), outer.len);
    try std.testing.expectEqualStrings("foo", outer[0].bulk_string);

    const inner = outer[1].array;
    try std.testing.expectEqual(@as(usize, 1), inner.len);
    try std.testing.expectEqual(@as(i64, 99), inner[0].integer);
}

test "decode empty bulk string" {
    const allocator = std.testing.allocator;
    const result = try decode(allocator, "$0\r\n\r\n");
    defer freeValue(allocator, result.value);
    try std.testing.expectEqualStrings("", result.value.bulk_string);
}

test "decode empty array" {
    const allocator = std.testing.allocator;
    const result = try decode(allocator, "*0\r\n");
    defer freeValue(allocator, result.value);
    try std.testing.expectEqual(@as(usize, 0), result.value.array.len);
    freeValue(allocator, result.value);
    // Prevent double-free: the defer above will also run,
    // but freeValue on an empty slice is safe (allocator.free on zero-len is a no-op?
    // Actually for Zig allocator, free of a zero-length slice is valid).
}

test "encode then decode roundtrip" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "SET", "counter", "100" };
    const encoded = try encode(allocator, &args);
    defer allocator.free(encoded);

    const result = try decode(allocator, encoded);
    defer freeValue(allocator, result.value);

    const arr = result.value.array;
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqualStrings("SET", arr[0].bulk_string);
    try std.testing.expectEqualStrings("counter", arr[1].bulk_string);
    try std.testing.expectEqualStrings("100", arr[2].bulk_string);
}

test "incomplete data returns error" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.Incomplete, decode(allocator, "+OK"));
    try std.testing.expectError(error.Incomplete, decode(allocator, "$5\r\nhel"));
    try std.testing.expectError(error.Incomplete, decode(allocator, ""));
    try std.testing.expectError(error.Incomplete, decode(allocator, "*2\r\n$3\r\nfoo\r\n"));
}

test "unknown type byte returns error" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnknownType, decode(allocator, "X\r\n"));
}
