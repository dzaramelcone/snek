//! Direct-to-buffer JSON serializer — zero allocation.
//!
//! Writes JSON tokens straight into a caller-provided []u8 buffer.
//! No intermediate representation, no allocator needed for output.
//! Uses std.fmt for number formatting.
//!
//! Source: direct serialization pattern (no intermediate tree)

const std = @import("std");

pub const SerializeError = error{BufferOverflow};

/// Direct-to-buffer JSON writer. Tracks position and emits commas automatically.
pub const Serializer = struct {
    buf: []u8,
    pos: usize = 0,
    depth: u16 = 0,
    /// Bit per nesting level: 0 = first element (no comma), 1 = needs comma.
    needs_comma: u64 = 0,

    pub fn init(buf: []u8) Serializer {
        return .{ .buf = buf };
    }

    pub fn beginObject(self: *Serializer) SerializeError!void {
        try self.writeCommaIfNeeded();
        try self.writeByte('{');
        self.pushLevel();
    }

    pub fn endObject(self: *Serializer) SerializeError!void {
        self.popLevel();
        try self.writeByte('}');
        self.markNotFirst();
    }

    pub fn beginArray(self: *Serializer) SerializeError!void {
        try self.writeCommaIfNeeded();
        try self.writeByte('[');
        self.pushLevel();
    }

    pub fn endArray(self: *Serializer) SerializeError!void {
        self.popLevel();
        try self.writeByte(']');
        self.markNotFirst();
    }

    /// Write an object key (followed by colon). Must be inside beginObject/endObject.
    pub fn key(self: *Serializer, k: []const u8) SerializeError!void {
        try self.writeCommaIfNeeded();
        try self.writeEscapedString(k);
        try self.writeByte(':');
        self.clearCommaFlag(); // value follows key, no comma before it
    }

    pub fn string(self: *Serializer, s: []const u8) SerializeError!void {
        try self.writeCommaIfNeeded();
        try self.writeEscapedString(s);
        self.markNotFirst();
    }

    pub fn integer(self: *Serializer, n: i64) SerializeError!void {
        try self.writeCommaIfNeeded();
        const result = std.fmt.bufPrint(self.buf[self.pos..], "{d}", .{n}) catch
            return SerializeError.BufferOverflow;
        self.pos += result.len;
        self.markNotFirst();
    }

    pub fn float(self: *Serializer, f: f64) SerializeError!void {
        try self.writeCommaIfNeeded();
        const result = std.fmt.bufPrint(self.buf[self.pos..], "{d}", .{f}) catch
            return SerializeError.BufferOverflow;
        self.pos += result.len;
        self.markNotFirst();
    }

    pub fn boolean(self: *Serializer, b: bool) SerializeError!void {
        try self.writeCommaIfNeeded();
        const s = if (b) "true" else "false";
        try self.writeSlice(s);
        self.markNotFirst();
    }

    pub fn null_(self: *Serializer) SerializeError!void {
        try self.writeCommaIfNeeded();
        try self.writeSlice("null");
        self.markNotFirst();
    }

    /// Get the written JSON output.
    pub fn output(self: *const Serializer) []const u8 {
        return self.buf[0..self.pos];
    }

    // -- internal helpers --

    fn writeByte(self: *Serializer, b: u8) SerializeError!void {
        if (self.pos >= self.buf.len) return SerializeError.BufferOverflow;
        self.buf[self.pos] = b;
        self.pos += 1;
    }

    fn writeSlice(self: *Serializer, s: []const u8) SerializeError!void {
        if (self.pos + s.len > self.buf.len) return SerializeError.BufferOverflow;
        @memcpy(self.buf[self.pos..][0..s.len], s);
        self.pos += s.len;
    }

    fn writeEscapedString(self: *Serializer, s: []const u8) SerializeError!void {
        try self.writeByte('"');
        for (s) |c| {
            switch (c) {
                '"' => try self.writeSlice("\\\""),
                '\\' => try self.writeSlice("\\\\"),
                '\n' => try self.writeSlice("\\n"),
                '\r' => try self.writeSlice("\\r"),
                '\t' => try self.writeSlice("\\t"),
                0x08 => try self.writeSlice("\\b"),
                0x0c => try self.writeSlice("\\f"),
                else => {
                    if (c < 0x20) {
                        // Control characters as \u00XX
                        const hex = std.fmt.bufPrint(self.buf[self.pos..], "\\u{x:0>4}", .{c}) catch
                            return SerializeError.BufferOverflow;
                        self.pos += hex.len;
                    } else {
                        try self.writeByte(c);
                    }
                },
            }
        }
        try self.writeByte('"');
    }

    fn writeCommaIfNeeded(self: *Serializer) SerializeError!void {
        if (self.depth > 0 and (self.needs_comma & (@as(u64, 1) << @intCast(self.depth - 1))) != 0) {
            try self.writeByte(',');
        }
    }

    fn pushLevel(self: *Serializer) void {
        self.depth += 1;
        // Clear the bit for this new level (first element, no comma).
        self.needs_comma &= ~(@as(u64, 1) << @intCast(self.depth - 1));
    }

    fn popLevel(self: *Serializer) void {
        self.depth -= 1;
    }

    fn markNotFirst(self: *Serializer) void {
        if (self.depth > 0) {
            self.needs_comma |= @as(u64, 1) << @intCast(self.depth - 1);
        }
    }

    fn clearCommaFlag(self: *Serializer) void {
        if (self.depth > 0) {
            self.needs_comma &= ~(@as(u64, 1) << @intCast(self.depth - 1));
        }
    }
};

/// Convenience: serialize a std.json.Value to an allocator-owned string.
/// Caller must free the returned slice with the same allocator.
pub fn stringify(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.write(value);
    const written = out.written();
    const duped = try allocator.alloc(u8, written.len);
    @memcpy(duped, written);
    return duped;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const json_parse = @import("parse.zig");

test "serialize simple object" {
    var buf: [256]u8 = undefined;
    var s = Serializer.init(&buf);
    try s.beginObject();
    try s.key("name");
    try s.string("snek");
    try s.key("version");
    try s.integer(1);
    try s.endObject();

    try std.testing.expectEqualStrings("{\"name\":\"snek\",\"version\":1}", s.output());
}

test "serialize nested" {
    var buf: [256]u8 = undefined;
    var s = Serializer.init(&buf);
    try s.beginObject();
    try s.key("user");
    try s.beginObject();
    try s.key("id");
    try s.integer(42);
    try s.key("name");
    try s.string("dzara");
    try s.endObject();
    try s.endObject();

    try std.testing.expectEqualStrings("{\"user\":{\"id\":42,\"name\":\"dzara\"}}", s.output());
}

test "serialize array" {
    var buf: [256]u8 = undefined;
    var s = Serializer.init(&buf);
    try s.beginArray();
    try s.integer(1);
    try s.integer(2);
    try s.integer(3);
    try s.endArray();

    try std.testing.expectEqualStrings("[1,2,3]", s.output());
}

test "serialize string escaping" {
    var buf: [256]u8 = undefined;
    var s = Serializer.init(&buf);
    try s.string("hello \"world\"\nline\\two");

    try std.testing.expectEqualStrings("\"hello \\\"world\\\"\\nline\\\\two\"", s.output());
}

test "serialize round-trip" {
    const allocator = std.testing.allocator;
    const input =
        \\{"name":"snek","version":1}
    ;
    const parsed = try json_parse.parse(allocator, input);
    defer parsed.deinit();

    const output = try stringify(allocator, parsed.value);
    defer allocator.free(output);

    // Re-parse the output and compare field values (order may differ in hash maps).
    const reparsed = try json_parse.parse(allocator, output);
    defer reparsed.deinit();

    try std.testing.expectEqualStrings("snek", json_parse.getString(reparsed.value, "name").?);
    try std.testing.expectEqual(@as(i64, 1), json_parse.getInt(reparsed.value, "version").?);
}

test "buffer overflow returns error" {
    var buf: [5]u8 = undefined;
    var s = Serializer.init(&buf);
    try s.beginObject();
    try s.key("a");
    const result = s.string("this is way too long for the buffer");
    try std.testing.expectError(SerializeError.BufferOverflow, result);
}
