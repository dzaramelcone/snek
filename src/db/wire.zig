//! Postgres v3 wire protocol: message encoding/decoding for the simple query protocol.
//!
//! Implements StartupMessage, Query, and backend message parsing (RowDescription,
//! DataRow, CommandComplete, ReadyForQuery, ErrorResponse, ParameterStatus, Auth).
//!
//! Each backend message: 1 byte tag + 4 byte length (big-endian, includes self) + payload.
//! StartupMessage has no tag: 4 byte length + 4 byte protocol version + key=value\0 pairs + \0.
//!
//! Sources:
//!   - PostgreSQL Frontend/Backend Protocol v3: https://www.postgresql.org/docs/current/protocol.html
//!   - extern struct with @sizeOf comptime assertions: TigerBeetle (refs/tigerbeetle/INSIGHTS.md)
//!   - Native wire implementation (no libpq): modeled after pgx (Go) — see src/db/REFERENCES.md

const std = @import("std");
const mem = std.mem;
const posix = std.posix;

/// Protocol version 3.0 = 196608
pub const protocol_version: u32 = 196608;

/// SSL request code (sent before StartupMessage to negotiate SSL).
pub const ssl_request_code: u32 = 80877103;

// ─── Frontend message tags ───────────────────────────────────────────

pub const Tag = struct {
    pub const query: u8 = 'Q';
    pub const parse: u8 = 'P';
    pub const bind: u8 = 'B';
    pub const execute: u8 = 'E';
    pub const describe: u8 = 'D';
    pub const sync: u8 = 'S';
    pub const flush: u8 = 'H';
    pub const close: u8 = 'C';
    pub const terminate: u8 = 'X';
    pub const copy_data: u8 = 'd';
    pub const copy_done: u8 = 'c';
    pub const copy_fail: u8 = 'f';
    pub const password_message: u8 = 'p';
};

// ─── Backend message tags ────────────────────────────────────────────

pub const BackendTag = struct {
    pub const authentication: u8 = 'R';
    pub const backend_key_data: u8 = 'K';
    pub const ready_for_query: u8 = 'Z';
    pub const row_description: u8 = 'T';
    pub const data_row: u8 = 'D';
    pub const command_complete: u8 = 'C';
    pub const error_response: u8 = 'E';
    pub const notice_response: u8 = 'N';
    pub const notification_response: u8 = 'A';
    pub const parameter_status: u8 = 'S';
    pub const parse_complete: u8 = '1';
    pub const bind_complete: u8 = '2';
    pub const close_complete: u8 = '3';
    pub const no_data: u8 = 'n';
    pub const empty_query_response: u8 = 'I';
    pub const copy_in_response: u8 = 'G';
    pub const copy_out_response: u8 = 'H';
};

// ─── Auth subtypes ───────────────────────────────────────────────────

pub const AuthType = enum(u32) {
    ok = 0,
    kerberos_v5 = 2,
    cleartext_password = 3,
    md5_password = 5,
    scm_credential = 6,
    gss = 7,
    gss_continue = 8,
    sspi = 9,
    sasl = 10,
    sasl_continue = 11,
    sasl_final = 12,
};

// ─── Transaction status ──────────────────────────────────────────────

pub const TransactionStatus = enum(u8) {
    idle = 'I',
    in_transaction = 'T',
    failed = 'E',
};

// ─── ErrorResponse field codes ───────────────────────────────────────

pub const ErrorField = enum(u8) {
    severity = 'S',
    severity_v = 'V',
    code = 'C',
    message = 'M',
    detail = 'D',
    hint = 'H',
    position = 'P',
    internal_position = 'p',
    internal_query = 'q',
    where = 'W',
    schema = 's',
    table = 't',
    column = 'c',
    data_type = 'd',
    constraint = 'n',
    file = 'F',
    line = 'L',
    routine = 'R',
};

// ─── Wire message extern structs ─────────────────────────────────────
// Pattern: extern struct + comptime @sizeOf assertion + noPadding check.
// Source: TigerBeetle (refs/tigerbeetle/INSIGHTS.md) — guarantees wire-compatible
// layout with zero padding, caught at compile time rather than runtime.

/// Generic message header: tag (1 byte) + length (4 bytes big-endian).
pub const MessageHeader = extern struct {
    tag: u8,
    length: u32 align(1),

    comptime {
        std.debug.assert(@sizeOf(MessageHeader) == 5);
        std.debug.assert(!@import("std").meta.hasUniqueRepresentation(MessageHeader) or noPadding(MessageHeader));
    }
};

/// SSLRequest: sent before StartupMessage. No tag byte — length + code only.
pub const SSLRequest = extern struct {
    length: u32 align(1),
    code: u32 align(1),

    comptime {
        std.debug.assert(@sizeOf(SSLRequest) == 8);
    }
};

/// StartupMessage: no tag byte. length + protocol_version + params.
pub const StartupMessageHeader = extern struct {
    length: u32 align(1),
    protocol_version: u32 align(1),

    comptime {
        std.debug.assert(@sizeOf(StartupMessageHeader) == 8);
    }
};

/// AuthenticationOk (R + length=8 + status=0).
pub const AuthenticationOk = extern struct {
    tag: u8,
    length: u32 align(1),
    status: u32 align(1),

    comptime {
        std.debug.assert(@sizeOf(AuthenticationOk) == 9);
    }
};

/// AuthenticationMD5Password (R + length=12 + status=5 + salt[4]).
pub const AuthenticationMD5 = extern struct {
    tag: u8,
    length: u32 align(1),
    status: u32 align(1),
    salt: [4]u8,

    comptime {
        std.debug.assert(@sizeOf(AuthenticationMD5) == 13);
    }
};

/// BackendKeyData (K + length=12 + pid + secret).
pub const BackendKeyData = extern struct {
    tag: u8,
    length: u32 align(1),
    process_id: u32 align(1),
    secret_key: u32 align(1),

    comptime {
        std.debug.assert(@sizeOf(BackendKeyData) == 13);
    }
};

/// ReadyForQuery (Z + length=5 + status).
pub const ReadyForQuery = extern struct {
    tag: u8,
    length: u32 align(1),
    status: u8,

    comptime {
        std.debug.assert(@sizeOf(ReadyForQuery) == 6);
    }
};

// ─── Tracked server parameters ───────────────────────────────────────

pub const ServerParams = struct {
    server_version: []const u8,
    server_encoding: []const u8,
    client_encoding: []const u8,
    timezone: []const u8,
    integer_datetimes: bool,
};

// ─── Parsed error/notice ─────────────────────────────────────────────

pub const ErrorNotice = struct {
    severity: []const u8,
    code: []const u8,
    message: []const u8,
    detail: ?[]const u8,
    hint: ?[]const u8,
    position: ?[]const u8,
};

// ─── Notification (LISTEN/NOTIFY) ────────────────────────────────────

pub const Notification = struct {
    pid: u32,
    channel: []const u8,
    payload: []const u8,
};

// ─── noPadding helper (mirrors TigerBeetle's stdx.no_padding) ────────
// Source: TigerBeetle stdx.zig — sum of field sizes must equal @sizeOf(T),
// ensuring the compiler inserted no padding bytes.

fn noPadding(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return true;
    var total: usize = 0;
    for (info.@"struct".fields) |f| {
        total += @sizeOf(f.type);
    }
    return total == @sizeOf(T);
}

// ─── Errors ──────────────────────────────────────────────────────────

pub const WireError = error{
    UnexpectedMessage,
    ServerError,
    UnsupportedAuth,
    ProtocolViolation,
    ConnectionClosed,
};

// ─── Encoding: Frontend → Backend ────────────────────────────────────
// Source: PostgreSQL protocol v3 message formats
// https://www.postgresql.org/docs/current/protocol-message-formats.html

/// Encode a StartupMessage into buf. Returns the slice of buf that was written.
/// Format: length(u32) + protocol_version(u32) + ("user\0" + user + "\0") + ("database\0" + db + "\0") + "\0"
pub fn encodeStartupMessage(buf: []u8, user: []const u8, database: []const u8) []const u8 {
    // Payload: "user\0" + user + "\0" + "database\0" + database + "\0" + "\0" (terminator)
    const payload_len = 4 + // protocol version
        5 + user.len + 1 + // "user\0" + user + "\0"
        9 + database.len + 1 + // "database\0" + database + "\0"
        1; // final null terminator
    const total_len: u32 = @intCast(4 + payload_len); // length field includes itself

    var pos: usize = 0;
    // Length (big-endian u32)
    @memcpy(buf[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, total_len, .big)));
    pos += 4;
    // Protocol version (big-endian u32)
    @memcpy(buf[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, protocol_version, .big)));
    pos += 4;
    // "user\0"
    @memcpy(buf[pos..][0..5], "user\x00");
    pos += 5;
    @memcpy(buf[pos..][0..user.len], user);
    pos += user.len;
    buf[pos] = 0;
    pos += 1;
    // "database\0"
    @memcpy(buf[pos..][0..9], "database\x00");
    pos += 9;
    @memcpy(buf[pos..][0..database.len], database);
    pos += database.len;
    buf[pos] = 0;
    pos += 1;
    // Final null terminator
    buf[pos] = 0;
    pos += 1;

    return buf[0..pos];
}

/// Encode a simple Query message ('Q').
/// Format: tag('Q') + length(u32) + sql + '\0'
pub fn encodeQuery(buf: []u8, sql: []const u8) []const u8 {
    const length: u32 = @intCast(4 + sql.len + 1); // length includes itself + sql + null
    var pos: usize = 0;

    buf[pos] = Tag.query;
    pos += 1;
    @memcpy(buf[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, length, .big)));
    pos += 4;
    @memcpy(buf[pos..][0..sql.len], sql);
    pos += sql.len;
    buf[pos] = 0;
    pos += 1;

    return buf[0..pos];
}

/// Encode a PasswordMessage ('p').
/// Format: tag('p') + length(u32) + password + '\0'
pub fn encodePasswordMessage(buf: []u8, password: []const u8) []const u8 {
    const length: u32 = @intCast(4 + password.len + 1);
    var pos: usize = 0;

    buf[pos] = Tag.password_message;
    pos += 1;
    @memcpy(buf[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, length, .big)));
    pos += 4;
    @memcpy(buf[pos..][0..password.len], password);
    pos += password.len;
    buf[pos] = 0;
    pos += 1;

    return buf[0..pos];
}

/// Encode a Terminate message ('X').
/// Format: tag('X') + length(4) = 5 bytes total
pub fn encodeTerminate(buf: []u8) []const u8 {
    buf[0] = Tag.terminate;
    @memcpy(buf[1..5], &mem.toBytes(mem.nativeTo(u32, @as(u32, 4), .big)));
    return buf[0..5];
}

// ─── Decoding: Backend → Frontend ────────────────────────────────────

/// Read a message header (5 bytes): 1 byte tag + 4 byte length.
/// Returns the header. The length field includes itself but not the tag byte,
/// so payload_len = header.length - 4.
pub fn readMessageHeader(data: []const u8) WireError!MessageHeader {
    if (data.len < 5) return WireError.ProtocolViolation;
    return .{
        .tag = data[0],
        .length = mem.bigToNative(u32, mem.bytesToValue(u32, data[1..5])),
    };
}

/// Column descriptor from RowDescription.
pub const ColumnDesc = struct {
    name: []const u8,
    table_oid: u32,
    column_attr: u16,
    type_oid: u32,
    type_len: i16,
    type_mod: i32,
    format: u16,
};

/// Parse a RowDescription payload (after the 5-byte header).
/// Format: field_count(u16) + for each field:
///   name(null-terminated) + table_oid(u32) + column_attr(u16) + type_oid(u32) +
///   type_len(i16) + type_mod(i32) + format(u16)
pub fn parseRowDescription(payload: []const u8, columns_out: []ColumnDesc) WireError!u16 {
    if (payload.len < 2) return WireError.ProtocolViolation;
    const field_count = mem.bigToNative(u16, mem.bytesToValue(u16, payload[0..2]));
    if (field_count > columns_out.len) return WireError.ProtocolViolation;

    var pos: usize = 2;
    for (0..field_count) |i| {
        const name_start = pos;
        while (pos < payload.len and payload[pos] != 0) : (pos += 1) {}
        if (pos >= payload.len) return WireError.ProtocolViolation;
        const name = payload[name_start..pos];
        pos += 1; // skip null

        // 18 bytes of fixed fields after the name
        if (pos + 18 > payload.len) return WireError.ProtocolViolation;
        columns_out[i] = .{
            .name = name,
            .table_oid = mem.bigToNative(u32, mem.bytesToValue(u32, payload[pos..][0..4])),
            .column_attr = mem.bigToNative(u16, mem.bytesToValue(u16, payload[pos + 4 ..][0..2])),
            .type_oid = mem.bigToNative(u32, mem.bytesToValue(u32, payload[pos + 6 ..][0..4])),
            .type_len = @bitCast(mem.bigToNative(u16, mem.bytesToValue(u16, payload[pos + 10 ..][0..2]))),
            .type_mod = @bitCast(mem.bigToNative(u32, mem.bytesToValue(u32, payload[pos + 12 ..][0..4]))),
            .format = mem.bigToNative(u16, mem.bytesToValue(u16, payload[pos + 16 ..][0..2])),
        };
        pos += 18;
    }
    return field_count;
}

/// Parse a DataRow payload (after the 5-byte header).
/// Format: column_count(u16) + for each column:
///   value_len(i32) — if -1, NULL; otherwise value_len bytes of data.
/// Returns the number of columns parsed. Values are written to values_out as slices
/// into the payload buffer (zero-copy).
pub fn parseDataRow(payload: []const u8, values_out: []?[]const u8) WireError!u16 {
    if (payload.len < 2) return WireError.ProtocolViolation;
    const col_count = mem.bigToNative(u16, mem.bytesToValue(u16, payload[0..2]));
    if (col_count > values_out.len) return WireError.ProtocolViolation;

    var pos: usize = 2;
    for (0..col_count) |i| {
        if (pos + 4 > payload.len) return WireError.ProtocolViolation;
        const val_len: i32 = @bitCast(mem.bigToNative(u32, mem.bytesToValue(u32, payload[pos..][0..4])));
        pos += 4;

        if (val_len == -1) {
            values_out[i] = null; // SQL NULL
        } else {
            const ulen: usize = @intCast(val_len);
            if (pos + ulen > payload.len) return WireError.ProtocolViolation;
            values_out[i] = payload[pos..][0..ulen];
            pos += ulen;
        }
    }
    return col_count;
}

/// Parse a CommandComplete payload — just a null-terminated string like "SELECT 3" or "INSERT 0 1".
pub fn parseCommandComplete(payload: []const u8) []const u8 {
    var end: usize = 0;
    while (end < payload.len and payload[end] != 0) : (end += 1) {}
    return payload[0..end];
}

/// Parse an ErrorResponse or NoticeResponse payload.
/// Format: repeated (field_code(u8) + value(null-terminated)), terminated by '\0'.
pub fn parseErrorFields(payload: []const u8) ErrorNotice {
    var result = ErrorNotice{
        .severity = "",
        .code = "",
        .message = "",
        .detail = null,
        .hint = null,
        .position = null,
    };

    var pos: usize = 0;
    while (pos < payload.len) {
        const field_byte = payload[pos];
        if (field_byte == 0) break;
        pos += 1;

        const val_start = pos;
        while (pos < payload.len and payload[pos] != 0) : (pos += 1) {}
        const val = payload[val_start..pos];
        if (pos < payload.len) pos += 1; // skip null

        switch (field_byte) {
            'S' => result.severity = val,
            'C' => result.code = val,
            'M' => result.message = val,
            'D' => result.detail = val,
            'H' => result.hint = val,
            'P' => result.position = val,
            else => {}, // ignore unknown fields
        }
    }
    return result;
}

/// Parse a ParameterStatus payload: name(null-terminated) + value(null-terminated).
pub fn parseParameterStatus(payload: []const u8) struct { name: []const u8, value: []const u8 } {
    var pos: usize = 0;
    // Find name
    const name_start = pos;
    while (pos < payload.len and payload[pos] != 0) : (pos += 1) {}
    const name = payload[name_start..pos];
    if (pos < payload.len) pos += 1;
    // Find value
    const val_start = pos;
    while (pos < payload.len and payload[pos] != 0) : (pos += 1) {}
    const value = payload[val_start..pos];
    return .{ .name = name, .value = value };
}

/// Parse the auth type from an Authentication message payload (first 4 bytes after header).
pub fn parseAuthType(payload: []const u8) WireError!AuthType {
    if (payload.len < 4) return WireError.ProtocolViolation;
    const raw = mem.bigToNative(u32, mem.bytesToValue(u32, payload[0..4]));
    return std.meta.intToEnum(AuthType, raw) catch WireError.UnsupportedAuth;
}

/// Extract MD5 salt from an AuthenticationMD5Password payload (bytes 4..8).
pub fn parseMd5Salt(payload: []const u8) WireError![4]u8 {
    if (payload.len < 8) return WireError.ProtocolViolation;
    return payload[4..8].*;
}

// ─── Generic-over-IO wire connection (stub retained for future phases) ─
// Full implementation deferred to when the IO abstraction layer is ready.
// Phase 10 MVP uses std.posix directly in query.zig instead.

pub fn WireConnectionType(comptime IO: type) type {
    return struct {
        const Self = @This();

        io: *IO,
        fd: i32,
        server_params: ServerParams,
        process_id: u32,
        secret_key: u32,
        tx_status: TransactionStatus,

        pub fn sslNegotiate(self: *Self) !bool {
            _ = self;
            @panic("WireConnectionType.sslNegotiate: not yet implemented — use query.Client for MVP");
        }

        pub fn startup(self: *Self, user: []const u8, database: []const u8) !void {
            _ = .{ self, user, database };
            @panic("WireConnectionType.startup: not yet implemented — use query.Client for MVP");
        }

        pub fn authenticate(self: *Self, password: []const u8) !void {
            _ = .{ self, password };
            @panic("WireConnectionType.authenticate: not yet implemented — use query.Client for MVP");
        }

        pub fn sendQuery(self: *Self, sql: []const u8) !void {
            _ = .{ self, sql };
            @panic("WireConnectionType.sendQuery: not yet implemented — use query.Client for MVP");
        }

        pub fn sendParse(self: *Self, name: []const u8, sql: []const u8, param_oids: []const u32) !void {
            _ = .{ self, name, sql, param_oids };
            @panic("WireConnectionType.sendParse: not yet implemented");
        }

        pub fn sendBind(self: *Self, portal: []const u8, statement: []const u8, params: []const ?[]const u8, format_codes: []const u16) !void {
            _ = .{ self, portal, statement, params, format_codes };
            @panic("WireConnectionType.sendBind: not yet implemented");
        }

        pub fn sendExecute(self: *Self, portal: []const u8, max_rows: u32) !void {
            _ = .{ self, portal, max_rows };
            @panic("WireConnectionType.sendExecute: not yet implemented");
        }

        pub fn sendDescribe(self: *Self, kind: u8, name: []const u8) !void {
            _ = .{ self, kind, name };
            @panic("WireConnectionType.sendDescribe: not yet implemented");
        }

        pub fn sendSync(self: *Self) !void {
            _ = self;
            @panic("WireConnectionType.sendSync: not yet implemented");
        }

        pub fn sendFlush(self: *Self) !void {
            _ = self;
            @panic("WireConnectionType.sendFlush: not yet implemented");
        }

        pub fn sendTerminate(self: *Self) !void {
            _ = self;
            @panic("WireConnectionType.sendTerminate: not yet implemented");
        }

        pub fn readMessage(self: *Self) !MessageHeader {
            _ = self;
            @panic("WireConnectionType.readMessage: not yet implemented");
        }

        pub fn parseErrorResponse(self: *Self, payload: []const u8) ErrorNotice {
            _ = self;
            return parseErrorFields(payload);
        }

        pub fn parseNoticeResponse(self: *Self, payload: []const u8) ErrorNotice {
            _ = self;
            return parseErrorFields(payload);
        }

        pub fn parseNotification(self: *Self, payload: []const u8) Notification {
            _ = self;
            if (payload.len < 4) @panic("parseNotification: payload too short");
            const pid = mem.bigToNative(u32, mem.bytesToValue(u32, payload[0..4]));
            var pos: usize = 4;
            const ch_start = pos;
            while (pos < payload.len and payload[pos] != 0) : (pos += 1) {}
            const channel = payload[ch_start..pos];
            if (pos < payload.len) pos += 1;
            const pl_start = pos;
            while (pos < payload.len and payload[pos] != 0) : (pos += 1) {}
            return .{ .pid = pid, .channel = channel, .payload = payload[pl_start..pos] };
        }

        pub fn handleParameterStatus(self: *Self, payload: []const u8) void {
            _ = .{ self, payload };
        }

        pub fn close(self: *Self) void {
            _ = self;
        }
    };
}

// ─── Tests ───────────────────────────────────────────────────────────

test "wire extern struct sizes" {
    // Verify all extern struct sizes match Postgres wire protocol expectations.
    // Source: TigerBeetle pattern — catch layout issues at comptime.
    try std.testing.expectEqual(@as(usize, 5), @sizeOf(MessageHeader));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(SSLRequest));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(StartupMessageHeader));
    try std.testing.expectEqual(@as(usize, 9), @sizeOf(AuthenticationOk));
    try std.testing.expectEqual(@as(usize, 13), @sizeOf(AuthenticationMD5));
    try std.testing.expectEqual(@as(usize, 13), @sizeOf(BackendKeyData));
    try std.testing.expectEqual(@as(usize, 6), @sizeOf(ReadyForQuery));
}

test "startup message encoding" {
    var buf: [256]u8 = undefined;
    const msg = encodeStartupMessage(&buf, "postgres", "mydb");

    // Parse back: length(4) + version(4) + "user\0postgres\0database\0mydb\0\0"
    const length = mem.bigToNative(u32, mem.bytesToValue(u32, msg[0..4]));
    try std.testing.expectEqual(length, @as(u32, @intCast(msg.len)));

    const version = mem.bigToNative(u32, mem.bytesToValue(u32, msg[4..8]));
    try std.testing.expectEqual(version, protocol_version);

    // Find "user" key
    try std.testing.expectEqualStrings("user", msg[8..12]);
    try std.testing.expectEqual(msg[12], 0);
    try std.testing.expectEqualStrings("postgres", msg[13..21]);
    try std.testing.expectEqual(msg[21], 0);

    // Find "database" key
    try std.testing.expectEqualStrings("database", msg[22..30]);
    try std.testing.expectEqual(msg[30], 0);
    try std.testing.expectEqualStrings("mydb", msg[31..35]);
    try std.testing.expectEqual(msg[35], 0);

    // Final terminator
    try std.testing.expectEqual(msg[36], 0);
}

test "query message encoding" {
    var buf: [256]u8 = undefined;
    const msg = encodeQuery(&buf, "SELECT 1");

    try std.testing.expectEqual(msg[0], Tag.query);
    const length = mem.bigToNative(u32, mem.bytesToValue(u32, msg[1..5]));
    // length = 4 (self) + 8 (sql) + 1 (null) = 13
    try std.testing.expectEqual(length, 13);
    try std.testing.expectEqualStrings("SELECT 1", msg[5..13]);
    try std.testing.expectEqual(msg[13], 0);
}

test "password message encoding" {
    var buf: [256]u8 = undefined;
    const msg = encodePasswordMessage(&buf, "secret");

    try std.testing.expectEqual(msg[0], Tag.password_message);
    const length = mem.bigToNative(u32, mem.bytesToValue(u32, msg[1..5]));
    try std.testing.expectEqual(length, 11); // 4 + 6 + 1
    try std.testing.expectEqualStrings("secret", msg[5..11]);
    try std.testing.expectEqual(msg[11], 0);
}

test "terminate message encoding" {
    var buf: [8]u8 = undefined;
    const msg = encodeTerminate(&buf);

    try std.testing.expectEqual(msg.len, 5);
    try std.testing.expectEqual(msg[0], Tag.terminate);
    const length = mem.bigToNative(u32, mem.bytesToValue(u32, msg[1..5]));
    try std.testing.expectEqual(length, 4);
}

test "message header parsing" {
    // Simulate an AuthenticationOk: R + length=8 + status=0
    var data: [9]u8 = undefined;
    data[0] = BackendTag.authentication;
    @memcpy(data[1..5], &mem.toBytes(mem.nativeTo(u32, @as(u32, 8), .big)));
    @memcpy(data[5..9], &mem.toBytes(mem.nativeTo(u32, @as(u32, 0), .big)));

    const header = try readMessageHeader(&data);
    try std.testing.expectEqual(header.tag, BackendTag.authentication);
    try std.testing.expectEqual(header.length, 8);
}

test "row description parsing" {
    // Build a RowDescription payload: 2 columns
    var payload: [256]u8 = undefined;
    var pos: usize = 0;

    // field count = 2
    @memcpy(payload[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, @as(u16, 2), .big)));
    pos += 2;

    // Column 1: "id"
    @memcpy(payload[pos..][0..3], "id\x00");
    pos += 3;
    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @as(u32, 0), .big))); // table oid
    pos += 4;
    @memcpy(payload[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, @as(u16, 1), .big))); // column attr
    pos += 2;
    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @as(u32, 23), .big))); // type oid (int4)
    pos += 4;
    @memcpy(payload[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, @as(u16, 4), .big))); // type len
    pos += 2;
    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @as(u32, 0xFFFFFFFF), .big))); // type mod = -1
    pos += 4;
    @memcpy(payload[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, @as(u16, 0), .big))); // format (text)
    pos += 2;

    // Column 2: "name"
    @memcpy(payload[pos..][0..5], "name\x00");
    pos += 5;
    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @as(u32, 0), .big)));
    pos += 4;
    @memcpy(payload[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, @as(u16, 2), .big)));
    pos += 2;
    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @as(u32, 25), .big))); // type oid (text)
    pos += 4;
    @memcpy(payload[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, @bitCast(@as(i16, -1)), .big))); // type len = -1 (variable)
    pos += 2;
    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @as(u32, 0xFFFFFFFF), .big)));
    pos += 4;
    @memcpy(payload[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, @as(u16, 0), .big)));
    pos += 2;

    var columns: [8]ColumnDesc = undefined;
    const count = try parseRowDescription(payload[0..pos], &columns);

    try std.testing.expectEqual(count, 2);
    try std.testing.expectEqualStrings("id", columns[0].name);
    try std.testing.expectEqual(columns[0].type_oid, 23); // int4
    try std.testing.expectEqual(columns[0].type_len, 4);
    try std.testing.expectEqualStrings("name", columns[1].name);
    try std.testing.expectEqual(columns[1].type_oid, 25); // text
}

test "data row parsing" {
    // Build a DataRow payload: 3 columns — "42", NULL, "hello"
    var payload: [256]u8 = undefined;
    var pos: usize = 0;

    // column count = 3
    @memcpy(payload[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, @as(u16, 3), .big)));
    pos += 2;

    // Column 1: "42" (len=2)
    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @as(u32, 2), .big)));
    pos += 4;
    @memcpy(payload[pos..][0..2], "42");
    pos += 2;

    // Column 2: NULL (len=-1)
    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @bitCast(@as(i32, -1)), .big)));
    pos += 4;

    // Column 3: "hello" (len=5)
    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @as(u32, 5), .big)));
    pos += 4;
    @memcpy(payload[pos..][0..5], "hello");
    pos += 5;

    var values: [8]?[]const u8 = .{null} ** 8;
    const count = try parseDataRow(payload[0..pos], &values);

    try std.testing.expectEqual(count, 3);
    try std.testing.expectEqualStrings("42", values[0].?);
    try std.testing.expect(values[1] == null); // NULL
    try std.testing.expectEqualStrings("hello", values[2].?);
}

test "data row all nulls" {
    var payload: [10]u8 = undefined;
    var pos: usize = 0;

    // 2 columns, both NULL
    @memcpy(payload[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, @as(u16, 2), .big)));
    pos += 2;
    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @bitCast(@as(i32, -1)), .big)));
    pos += 4;
    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @bitCast(@as(i32, -1)), .big)));
    pos += 4;

    var values: [4]?[]const u8 = .{null} ** 4;
    const count = try parseDataRow(payload[0..pos], &values);
    try std.testing.expectEqual(count, 2);
    try std.testing.expect(values[0] == null);
    try std.testing.expect(values[1] == null);
}

test "data row empty string" {
    var payload: [8]u8 = undefined;
    var pos: usize = 0;

    // 1 column, empty string (len=0)
    @memcpy(payload[pos..][0..2], &mem.toBytes(mem.nativeTo(u16, @as(u16, 1), .big)));
    pos += 2;
    @memcpy(payload[pos..][0..4], &mem.toBytes(mem.nativeTo(u32, @as(u32, 0), .big)));
    pos += 4;
    // No data bytes for empty string

    var values: [4]?[]const u8 = .{null} ** 4;
    const count = try parseDataRow(payload[0..pos], &values);
    try std.testing.expectEqual(count, 1);
    try std.testing.expectEqual(values[0].?.len, 0);
}

test "command complete parsing" {
    const payload = "SELECT 42\x00";
    const tag = parseCommandComplete(payload);
    try std.testing.expectEqualStrings("SELECT 42", tag);
}

test "error response field parsing" {
    // Build an ErrorResponse payload
    const payload = "SERROR\x00" ++ "C42601\x00" ++ "Msyntax error\x00" ++ "Dsome detail\x00" ++ "Htry this\x00" ++ "\x00";
    const err = parseErrorFields(payload);

    try std.testing.expectEqualStrings("ERROR", err.severity);
    try std.testing.expectEqualStrings("42601", err.code);
    try std.testing.expectEqualStrings("syntax error", err.message);
    try std.testing.expectEqualStrings("some detail", err.detail.?);
    try std.testing.expectEqualStrings("try this", err.hint.?);
    try std.testing.expect(err.position == null);
}

test "error response minimal fields" {
    // Only severity, code, message — no optional fields
    const payload = "SERROR\x00" ++ "C42000\x00" ++ "Mfailed\x00" ++ "\x00";
    const err = parseErrorFields(payload);

    try std.testing.expectEqualStrings("ERROR", err.severity);
    try std.testing.expectEqualStrings("42000", err.code);
    try std.testing.expectEqualStrings("failed", err.message);
    try std.testing.expect(err.detail == null);
    try std.testing.expect(err.hint == null);
}

test "parameter status parsing" {
    const payload = "server_version\x00" ++ "16.2\x00";
    const ps = parseParameterStatus(payload);
    try std.testing.expectEqualStrings("server_version", ps.name);
    try std.testing.expectEqualStrings("16.2", ps.value);
}

test "auth type parsing" {
    // AuthenticationOk = 0
    var payload_ok: [4]u8 = undefined;
    @memcpy(&payload_ok, &mem.toBytes(mem.nativeTo(u32, @as(u32, 0), .big)));
    const auth_ok = try parseAuthType(&payload_ok);
    try std.testing.expectEqual(auth_ok, AuthType.ok);

    // AuthenticationMD5Password = 5
    var payload_md5: [8]u8 = undefined;
    @memcpy(payload_md5[0..4], &mem.toBytes(mem.nativeTo(u32, @as(u32, 5), .big)));
    @memcpy(payload_md5[4..8], &[4]u8{ 0xDE, 0xAD, 0xBE, 0xEF });
    const auth_md5 = try parseAuthType(&payload_md5);
    try std.testing.expectEqual(auth_md5, AuthType.md5_password);

    const salt = try parseMd5Salt(&payload_md5);
    try std.testing.expectEqual(salt, [4]u8{ 0xDE, 0xAD, 0xBE, 0xEF });

    // AuthenticationCleartextPassword = 3
    var payload_clear: [4]u8 = undefined;
    @memcpy(&payload_clear, &mem.toBytes(mem.nativeTo(u32, @as(u32, 3), .big)));
    const auth_clear = try parseAuthType(&payload_clear);
    try std.testing.expectEqual(auth_clear, AuthType.cleartext_password);
}

test "row description truncated payload" {
    // Payload too short — should error
    const payload = [_]u8{0};
    var columns: [4]ColumnDesc = undefined;
    const result = parseRowDescription(&payload, &columns);
    try std.testing.expectError(WireError.ProtocolViolation, result);
}

test "data row truncated payload" {
    // Only 1 byte — not enough for column count
    const payload = [_]u8{0};
    var values: [4]?[]const u8 = .{null} ** 4;
    const result = parseDataRow(&payload, &values);
    try std.testing.expectError(WireError.ProtocolViolation, result);
}

test "message header too short" {
    const data = [_]u8{ 'R', 0, 0 }; // only 3 bytes
    const result = readMessageHeader(&data);
    try std.testing.expectError(WireError.ProtocolViolation, result);
}

// ─── Retained empty stubs for tests that will be implemented in later phases ─

test "wire protocol connect" {}
test "wire protocol authenticate md5" {}
test "wire protocol authenticate scram" {}
test "wire protocol ssl negotiation" {}
test "wire protocol simple query" {}
test "wire protocol extended query parse" {}
test "wire protocol extended query bind" {}
test "wire protocol extended query execute" {}
test "wire protocol sync and flush" {}
test "wire protocol error response parsing" {}
test "wire protocol notice response parsing" {}
test "wire protocol notification response" {}
test "wire protocol parameter status tracking" {}
test "wire protocol close" {}

test "wire protocol RowDescription column name has no null terminator" {
    // Simulate what Postgres sends for "SELECT 1 AS num":
    // RowDescription with 1 column named "num"
    // Format: field_count(u16) + name("num\0") + table_oid(u32) + col_attr(u16) + type_oid(u32) + type_len(u16) + type_mod(u32) + format(u16)
    var payload: [64]u8 = undefined;
    var pos: usize = 0;
    
    // field_count = 1
    mem.writeInt(u16, payload[pos..][0..2], 1, .big);
    pos += 2;
    
    // name = "num\0"
    @memcpy(payload[pos..][0..3], "num");
    payload[pos + 3] = 0; // null terminator
    pos += 4;
    
    // 18 bytes of fixed fields (zeros for test)
    @memset(payload[pos..][0..18], 0);
    pos += 18;
    
    var columns: [16]ColumnDesc = undefined;
    const count = try parseRowDescription(payload[0..pos], &columns);
    
    try std.testing.expectEqual(@as(usize, 1), count);
    // The name MUST NOT include the null terminator
    try std.testing.expectEqual(@as(usize, 3), columns[0].name.len);
    try std.testing.expectEqualStrings("num", columns[0].name);
}
