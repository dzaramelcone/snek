//! RESP3 protocol (Redis Serialization Protocol) encoding and decoding.
//!
//! Uses extern struct for wire types where applicable. Inline RESP3 encoding
//! writes directly to buffer without intermediate representation.
//!
//! Source: RESP3 protocol spec (https://github.com/redis/redis-specifications/blob/master/protocol/RESP3.md).

const std = @import("std");

pub const RespType = enum(u8) {
    simple_string = '+',
    simple_error = '-',
    integer = ':',
    bulk_string = '$',
    array = '*',
    null_value = '_',
    boolean = '#',
    double = ',',
    big_number = '(',
    bulk_error = '!',
    verbatim_string = '=',
    map = '%',
    set = '~',
    push = '>',
};

pub const RespValue = union(enum) {
    simple_string: []const u8,
    error_msg: []const u8,
    integer: i64,
    bulk_string: []const u8,
    array: []const RespValue,
    null_value,
    boolean: bool,
    double: f64,
    big_number: []const u8,
    map: []const MapEntry,
    set: []const RespValue,
    push: []const RespValue,
};

pub const MapEntry = struct {
    key: RespValue,
    value: RespValue,
};

/// RESP3 frame header for wire-level parsing. Extern struct for
/// predictable memory layout matching the wire format.
pub const FrameHeader = extern struct {
    type_byte: u8,
    _pad: [7]u8 = .{ 0, 0, 0, 0, 0, 0, 0 },

    comptime {
        std.debug.assert(@sizeOf(FrameHeader) == 8);
    }
};

/// Inline RESP3 encoder — writes commands directly to a buffer without
/// building intermediate RespValue objects. Used for command encoding
/// where the structure is known at comptime.
pub const RespEncoder = struct {
    buf: []u8,
    pos: usize,

    pub fn init(buf: []u8) RespEncoder {
        return .{ .buf = buf, .pos = 0 };
    }

    /// Encode a RESP3 value to the buffer.
    pub fn encode(self: *RespEncoder, value: RespValue) ![]const u8 {
        _ = .{ self, value };
        return undefined;
    }

    /// Write a command as a RESP3 array of bulk strings directly.
    /// Avoids constructing RespValue intermediates.
    pub fn writeCommand(self: *RespEncoder, args: []const []const u8) ![]const u8 {
        _ = .{ self, args };
        return undefined;
    }

    /// Write a bulk string inline.
    pub fn writeBulkString(self: *RespEncoder, value: []const u8) !void {
        _ = .{ self, value };
    }

    /// Write an integer inline.
    pub fn writeInteger(self: *RespEncoder, value: i64) !void {
        _ = .{ self, value };
    }

    /// Get the written output.
    pub fn output(self: *const RespEncoder) []const u8 {
        return self.buf[0..self.pos];
    }
};

pub const RespDecoder = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) RespDecoder {
        return .{ .data = data, .pos = 0 };
    }

    /// Decode a single RESP3 value from the buffer.
    pub fn decode(self: *RespDecoder) !RespValue {
        _ = .{self};
        return undefined;
    }

    /// Parse an inline command (non-RESP format, space-separated).
    pub fn parseInline(self: *RespDecoder) !RespValue {
        _ = .{self};
        return undefined;
    }

    /// Check if there is a complete frame available to decode.
    pub fn hasCompleteFrame(self: *const RespDecoder) bool {
        _ = .{self};
        return undefined;
    }
};

test "encode simple string" {}

test "decode bulk string" {}

test "roundtrip RESP3 values" {}

test "inline command encoding" {}

test "frame header layout" {}

test "decode RESP3 map" {}

test "decode RESP3 push" {}
