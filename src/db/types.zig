//! Postgres type OID constants, binary/text format decoders, per-column format selection.
//!
//! Binary format decoders for: int2/int4/int8, float4/float8, bool, text/varchar,
//! bytea, timestamp/timestamptz, date, time, interval, uuid, json/jsonb, arrays, numeric.
//! Text format decoders as fallback.
//!
//! Sources:
//!   - Binary format by default for numeric/timestamp/array types: see src/db/REFERENCES.md.
//!     Binary is faster for these types; text is faster for pure varchar.
//!   - Per-column format selection in the Bind message: PostgreSQL extended query protocol.
//!     https://www.postgresql.org/docs/current/protocol-message-formats.html (Bind)
//!   - OID values: PostgreSQL pg_type catalog.

const std = @import("std");

// ─── Format codes for Bind message ───────────────────────────────────

pub const FormatCode = enum(u16) {
    text = 0,
    binary = 1,
};

// ─── OID constants for all supported types ───────────────────────────

pub const Oid = struct {
    pub const bool_oid: u32 = 16;
    pub const bytea_oid: u32 = 17;
    pub const int8_oid: u32 = 20;
    pub const int2_oid: u32 = 21;
    pub const int4_oid: u32 = 23;
    pub const text_oid: u32 = 25;
    pub const float4_oid: u32 = 700;
    pub const float8_oid: u32 = 701;
    pub const varchar_oid: u32 = 1043;
    pub const date_oid: u32 = 1082;
    pub const time_oid: u32 = 1083;
    pub const timestamp_oid: u32 = 1114;
    pub const timestamptz_oid: u32 = 1184;
    pub const interval_oid: u32 = 1186;
    pub const numeric_oid: u32 = 1700;
    pub const uuid_oid: u32 = 2950;
    pub const json_oid: u32 = 114;
    pub const jsonb_oid: u32 = 3802;
    // Array OIDs
    pub const bool_array_oid: u32 = 1000;
    pub const int2_array_oid: u32 = 1005;
    pub const int4_array_oid: u32 = 1007;
    pub const int8_array_oid: u32 = 1016;
    pub const float4_array_oid: u32 = 1021;
    pub const float8_array_oid: u32 = 1022;
    pub const text_array_oid: u32 = 1009;
    pub const varchar_array_oid: u32 = 1015;
    pub const uuid_array_oid: u32 = 2951;
    pub const json_array_oid: u32 = 199;
    pub const jsonb_array_oid: u32 = 3807;
    pub const timestamp_array_oid: u32 = 1115;
    pub const timestamptz_array_oid: u32 = 1185;
};

// ─── Postgres type enum ──────────────────────────────────────────────

pub const PgType = enum {
    boolean,
    smallint,
    integer,
    bigint,
    real,
    double_precision,
    text,
    varchar,
    bytea,
    timestamp,
    timestamptz,
    date,
    time,
    interval,
    uuid,
    json,
    jsonb,
    numeric,
    array,

    /// Map OID to PgType.
    pub fn fromOid(oid: u32) ?PgType {
        _ = .{oid};
        return undefined;
    }

    /// Preferred format code for this type (binary for numeric/timestamp/array, text for varchar).
    /// Source: benchmarks in src/db/REFERENCES.md — binary faster for numeric/timestamp/array,
    /// text faster for pure varchar workloads.
    pub fn preferredFormat(self: PgType) FormatCode {
        return switch (self) {
            .text, .varchar => .text,
            else => .binary,
        };
    }
};

// ─── Decoded value union ─────────────────────────────────────────────

pub const Value = union(enum) {
    null_value,
    bool_val: bool,
    i16_val: i16,
    i32_val: i32,
    i64_val: i64,
    f32_val: f32,
    f64_val: f64,
    text_val: []const u8,
    bytes_val: []const u8,
    uuid_val: [16]u8,
    json_val: []const u8,
};

// ─── Binary format decoders ──────────────────────────────────────────

pub fn decodeBool(raw: []const u8) !bool {
    _ = .{raw};
    return undefined;
}

pub fn decodeInt2(raw: []const u8) !i16 {
    _ = .{raw};
    return undefined;
}

pub fn decodeInt4(raw: []const u8) !i32 {
    _ = .{raw};
    return undefined;
}

pub fn decodeInt8(raw: []const u8) !i64 {
    _ = .{raw};
    return undefined;
}

pub fn decodeFloat4(raw: []const u8) !f32 {
    _ = .{raw};
    return undefined;
}

pub fn decodeFloat8(raw: []const u8) !f64 {
    _ = .{raw};
    return undefined;
}

pub fn decodeText(raw: []const u8) ![]const u8 {
    _ = .{raw};
    return undefined;
}

pub fn decodeBytea(raw: []const u8) ![]const u8 {
    _ = .{raw};
    return undefined;
}

pub fn decodeTimestamp(raw: []const u8) !i64 {
    _ = .{raw};
    return undefined;
}

pub fn decodeTimestamptz(raw: []const u8) !i64 {
    _ = .{raw};
    return undefined;
}

pub fn decodeDate(raw: []const u8) !i32 {
    _ = .{raw};
    return undefined;
}

pub fn decodeTime(raw: []const u8) !i64 {
    _ = .{raw};
    return undefined;
}

pub fn decodeInterval(raw: []const u8) !extern struct {
    microseconds: i64 align(1),
    days: i32 align(1),
    months: i32 align(1),

    comptime {
        std.debug.assert(@sizeOf(@This()) == 16);
    }
} {
    _ = .{raw};
    return undefined;
}

pub fn decodeUuid(raw: []const u8) ![16]u8 {
    _ = .{raw};
    return undefined;
}

pub fn decodeJson(raw: []const u8) ![]const u8 {
    _ = .{raw};
    return undefined;
}

pub fn decodeJsonb(raw: []const u8) ![]const u8 {
    _ = .{raw};
    return undefined;
}

pub fn decodeNumeric(raw: []const u8) ![]const u8 {
    _ = .{raw};
    return undefined;
}

pub fn decodeArray(raw: []const u8, element_oid: u32) ![]const Value {
    _ = .{ raw, element_oid };
    return undefined;
}

// ─── Text format decoders (fallback) ─────────────────────────────────

pub fn decodeTextBool(raw: []const u8) !bool {
    _ = .{raw};
    return undefined;
}

pub fn decodeTextInt(raw: []const u8) !i64 {
    _ = .{raw};
    return undefined;
}

pub fn decodeTextFloat(raw: []const u8) !f64 {
    _ = .{raw};
    return undefined;
}

pub fn decodeTextTimestamp(raw: []const u8) !i64 {
    _ = .{raw};
    return undefined;
}

pub fn decodeTextUuid(raw: []const u8) ![16]u8 {
    _ = .{raw};
    return undefined;
}

// ─── Encode helpers (Zig → Postgres wire format) ─────────────────────

pub fn encodeBool(value: bool) [1]u8 {
    _ = .{value};
    return undefined;
}

pub fn encodeInt2(value: i16) [2]u8 {
    _ = .{value};
    return undefined;
}

pub fn encodeInt4(value: i32) [4]u8 {
    _ = .{value};
    return undefined;
}

pub fn encodeInt8(value: i64) [8]u8 {
    _ = .{value};
    return undefined;
}

pub fn encodeFloat4(value: f32) [4]u8 {
    _ = .{value};
    return undefined;
}

pub fn encodeFloat8(value: f64) [8]u8 {
    _ = .{value};
    return undefined;
}

// ─── Per-column format selection for Bind message ────────────────────
// Source: PostgreSQL Bind message supports per-column result format codes,
// allowing mixed binary/text within a single query. See src/db/REFERENCES.md.

/// Given a list of column OIDs, return the preferred format code for each.
pub fn selectFormats(oids: []const u32, out: []FormatCode) void {
    _ = .{ oids, out };
}

// ─── Pg → Python conversion ─────────────────────────────────────────

pub fn pgToPython(pg_type: PgType, raw: []const u8) !*anyopaque {
    _ = .{ pg_type, raw };
    return undefined;
}

test "pg boolean binary decode" {}

test "pg int2 binary decode" {}

test "pg int4 binary decode" {}

test "pg int8 binary decode" {}

test "pg float4 binary decode" {}

test "pg float8 binary decode" {}

test "pg text decode" {}

test "pg bytea decode" {}

test "pg timestamp binary decode" {}

test "pg timestamptz binary decode" {}

test "pg date binary decode" {}

test "pg time binary decode" {}

test "pg interval binary decode" {}

test "pg uuid binary decode" {}

test "pg json decode" {}

test "pg jsonb decode" {}

test "pg numeric decode" {}

test "pg array decode" {}

test "pg text format bool fallback" {}

test "pg text format int fallback" {}

test "pg text format float fallback" {}

test "pg text format timestamp fallback" {}

test "pg text format uuid fallback" {}

test "pg type preferred format selection" {}

test "pg encode int4" {}

test "pg encode float8" {}

test "pg to python conversion" {}

test "oid to pg type mapping" {}
