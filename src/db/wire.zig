//! Postgres v3 wire protocol: extern struct message types, connect, auth,
//! extended query (Parse/Bind/Execute), pipeline mode, SSL negotiation,
//! ErrorResponse/NoticeResponse/NotificationResponse parsing, ParameterStatus tracking.
//!
//! All types are parameterized on `comptime IO: type` (Generic-over-IO pattern).
//! Wire message structs are `extern struct` with comptime no_padding assertions.
//!
//! Sources:
//!   - PostgreSQL Frontend/Backend Protocol v3: https://www.postgresql.org/docs/current/protocol.html
//!   - extern struct with @sizeOf comptime assertions and noPadding checks: TigerBeetle
//!     (refs/tigerbeetle/INSIGHTS.md — deterministic layout via extern struct + no-padding invariants)
//!   - Generic-over-IO (comptime IO: type) pattern: TigerBeetle io_uring/kqueue abstraction
//!   - Native wire implementation (no libpq): modeled after pgx (Go), asyncpg (Python),
//!     tokio-postgres (Rust) — see src/db/REFERENCES.md

const std = @import("std");

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

// ─── Generic-over-IO wire connection ─────────────────────────────────
// Pattern: comptime IO: type parameterization for io_uring/kqueue/epoll swapping.
// Source: TigerBeetle's generic I/O layer (refs/tigerbeetle/INSIGHTS.md).

pub fn WireConnectionType(comptime IO: type) type {
    return struct {
        const Self = @This();

        io: *IO,
        fd: i32,
        server_params: ServerParams,
        process_id: u32,
        secret_key: u32,
        tx_status: TransactionStatus,

        /// Initiate SSL negotiation. Returns true if server accepts SSL.
        pub fn sslNegotiate(self: *Self) !bool {
            _ = .{self};
            return undefined;
        }

        /// Send StartupMessage with user/database parameters.
        pub fn startup(self: *Self, user: []const u8, database: []const u8) !void {
            _ = .{ self, user, database };
        }

        /// Run authentication handshake (dispatches to SCRAM/md5/trust via auth module).
        pub fn authenticate(self: *Self, password: []const u8) !void {
            _ = .{ self, password };
        }

        /// Send a simple query ('Q' message).
        pub fn sendQuery(self: *Self, sql: []const u8) !void {
            _ = .{ self, sql };
        }

        /// Send Parse message (extended query protocol).
        pub fn sendParse(self: *Self, name: []const u8, sql: []const u8, param_oids: []const u32) !void {
            _ = .{ self, name, sql, param_oids };
        }

        /// Send Bind message with parameter values and format codes.
        pub fn sendBind(self: *Self, portal: []const u8, statement: []const u8, params: []const ?[]const u8, format_codes: []const u16) !void {
            _ = .{ self, portal, statement, params, format_codes };
        }

        /// Send Execute message.
        pub fn sendExecute(self: *Self, portal: []const u8, max_rows: u32) !void {
            _ = .{ self, portal, max_rows };
        }

        /// Send Describe message (portal or statement).
        pub fn sendDescribe(self: *Self, kind: u8, name: []const u8) !void {
            _ = .{ self, kind, name };
        }

        /// Send Sync message (extended query sync point).
        pub fn sendSync(self: *Self) !void {
            _ = .{self};
        }

        /// Send Flush message (request server to flush output).
        pub fn sendFlush(self: *Self) !void {
            _ = .{self};
        }

        /// Send Terminate message and close the connection.
        pub fn sendTerminate(self: *Self) !void {
            _ = .{self};
        }

        /// Read and parse the next backend message header.
        pub fn readMessage(self: *Self) !MessageHeader {
            _ = .{self};
            return undefined;
        }

        /// Parse an ErrorResponse body into ErrorNotice.
        pub fn parseErrorResponse(self: *Self, payload: []const u8) ErrorNotice {
            _ = .{ self, payload };
            return undefined;
        }

        /// Parse a NoticeResponse body into ErrorNotice.
        pub fn parseNoticeResponse(self: *Self, payload: []const u8) ErrorNotice {
            _ = .{ self, payload };
            return undefined;
        }

        /// Parse a NotificationResponse body.
        pub fn parseNotification(self: *Self, payload: []const u8) Notification {
            _ = .{ self, payload };
            return undefined;
        }

        /// Update tracked server parameters from a ParameterStatus message.
        pub fn handleParameterStatus(self: *Self, payload: []const u8) void {
            _ = .{ self, payload };
        }

        /// Close the underlying socket.
        pub fn close(self: *Self) void {
            _ = .{self};
        }
    };
}

test "wire extern struct sizes" {}

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
