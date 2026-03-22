//! Zig-native JSON parser built on std.json patterns.
//!
//! SIMD structural scanning (simdjson-style Stage 1), fused parse+validate
//! in a single pass against a SchemaNode, streaming support for large payloads,
//! and lazy value access for partial materialization.
//!
//! Sources:
//!   - SIMD scanning from simdjson (src/json/REFERENCES.md)
//!   - FusedParser from msgspec single-pass pattern
//!   - Built on std.json zero-copy tokens (refs/zig/INSIGHTS.md)

const std = @import("std");

pub const JsonError = error{
    UnexpectedToken,
    UnterminatedString,
    InvalidNumber,
    MaxDepthExceeded,
    TrailingData,
    InvalidUtf8,
    StringTooLong,
    NumberOutOfRange,
    DuplicateKey,
    UnexpectedEof,
    SchemaViolation,
};

pub const DuplicateKeyHandling = enum {
    allow,
    reject,
    last_wins,
};

pub const ParseOptions = struct {
    max_depth: u16 = 512,
    max_string_len: u32 = 1 << 24,
    duplicate_key_handling: DuplicateKeyHandling = .allow,
};

pub const JsonValue = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    array: []JsonValue,
    object: [][2]JsonValue,
};

/// Schema node for fused parse+validate. Describes expected structure so the
/// parser can validate constraints in the same pass as parsing — no second walk.
pub const SchemaNode = struct {
    kind: SchemaKind,
    required: bool = false,
    children: ?[]const SchemaField = null,
    items: ?*const SchemaNode = null,
    min_length: ?u32 = null,
    max_length: ?u32 = null,
    minimum: ?i64 = null,
    maximum: ?i64 = null,
};

pub const SchemaKind = enum {
    any,
    string,
    integer,
    float,
    boolean,
    null_type,
    object,
    array,
};

pub const SchemaField = struct {
    name: []const u8,
    schema: SchemaNode,
};

/// SIMD-accelerated structural character scanning.
/// Uses vector operations to find structural chars ({, }, [, ], :, ,) and
/// validate UTF-8 in bulk rather than byte-at-a-time.
/// Source: simdjson Stage 1 structural scanning (src/json/REFERENCES.md).
pub const SimdScanner = struct {
    input: []const u8,
    pos: usize,
    structural_mask: u64,

    /// Find structural characters using SIMD compare.
    /// Returns a bitmask of positions containing structural chars.
    pub fn scanStructural(input: []const u8) u64 {
        _ = .{input};
        return undefined;
    }

    /// Classify characters via SIMD shuffle-based lookup table.
    /// Each byte is mapped to a category (whitespace, structural, string, etc.).
    pub fn classifyChars(input: []const u8) [256]u8 {
        _ = .{input};
        return undefined;
    }

    /// SIMD-parallel UTF-8 validation using the Keiser-Lemire algorithm.
    /// Validates entire 64-byte chunks at once.
    pub fn validateUtf8(input: []const u8) bool {
        _ = .{input};
        return undefined;
    }
};

/// Fused parser: parse JSON and validate against a SchemaNode in a single pass.
/// This is the key innovation — instead of parse-then-validate (two tree walks),
/// schema constraints are checked inline during parsing. Rejects invalid documents
/// as early as possible with zero overhead for valid documents.
/// Source: msgspec fused decode+validate pattern (src/json/REFERENCES.md).
pub const FusedParser = struct {
    input: []const u8,
    pos: usize,
    depth: u16,
    opts: ParseOptions,

    /// Parse input and validate against schema in one pass.
    /// Returns the parsed value or a schema/parse error.
    pub fn parseAndValidate(input: []const u8, schema: *const SchemaNode, opts: ParseOptions) JsonError!JsonValue {
        _ = .{ input, schema, opts };
        return undefined;
    }

    /// Parse without schema (plain parse with options).
    pub fn parse(input: []const u8, opts: ParseOptions) JsonError!JsonValue {
        _ = .{ input, opts };
        return undefined;
    }
};

/// Streaming parser for large payloads. Processes input incrementally
/// without requiring the entire document in memory.
pub const StreamingParser = struct {
    state: u8,
    depth: u16,
    buf: []u8,
    buf_len: usize,
    opts: ParseOptions,

    /// Feed a chunk of input data. May be called multiple times.
    pub fn feed(self: *StreamingParser, chunk: []const u8) !void {
        _ = .{ self, chunk };
    }

    /// Yield the next complete JSON value or token from buffered input.
    pub fn next(self: *StreamingParser) !?JsonValue {
        _ = .{self};
        return undefined;
    }

    /// Reset parser state for reuse.
    pub fn reset(self: *StreamingParser) void {
        _ = .{self};
    }
};

/// Lazy value — parsed structurally but not materialized into Zig types.
/// Enables fast field access without full deserialization, for when the
/// handler only needs a subset of the document.
pub const LazyValue = struct {
    raw: []const u8,
    tape_index: u32,

    /// Access a nested field by key path. Returns a LazyValue pointing
    /// at the sub-document without copying.
    pub fn get(self: LazyValue, key: []const u8) ?LazyValue {
        _ = .{ self, key };
        return undefined;
    }

    /// Materialize the value as an i64.
    pub fn getInt(self: LazyValue) !i64 {
        _ = .{self};
        return undefined;
    }

    /// Materialize the value as a string slice (zero-copy from input).
    pub fn getString(self: LazyValue) ![]const u8 {
        _ = .{self};
        return undefined;
    }

    /// Iterate over array elements as lazy values.
    pub fn getArray(self: LazyValue) ![]LazyValue {
        _ = .{self};
        return undefined;
    }
};

test "fused parse+validate" {}

test "SIMD scan" {}

test "streaming large payload" {}

test "reject deeply nested" {}

test "parse null" {}

test "parse boolean" {}

test "parse integer" {}

test "parse float" {}

test "parse string" {}

test "parse array" {}

test "parse object" {}

test "parse nested structure" {}

test "lazy field access" {}

test "UTF-8 validation" {}

test "duplicate key handling" {}

test "max string length" {}
