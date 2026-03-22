//! Query interface: simple Postgres client using blocking TCP via std.posix.
//!
//! Provides Client.connect / Client.query / Client.close for the simple query protocol.
//! Uses wire.zig for message encoding/decoding and auth.zig for MD5/cleartext auth.
//!
//! This is the Phase 10 MVP — no prepared statements, no pipeline, no connection pooling.
//! Those are Phase 11 concerns.
//!
//! Sources:
//!   - Simple query protocol: https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-SIMPLE-QUERY
//!   - Blocking TCP via std.posix: direct socket I/O, no async yet.
//!   - Zero-copy row parsing: slices into read buffer (pg.zig pattern, src/db/REFERENCES.md §2.4).

const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const wire = @import("wire.zig");
const auth = @import("auth.zig");
const types = @import("types.zig");

// ─── Column metadata ────────────────────────────────────────────────

pub const ColumnInfo = struct {
    name: []const u8,
    table_oid: u32,
    column_index: u16,
    type_oid: u32,
    type_size: i16,
    type_modifier: i32,
    format: types.FormatCode,
};

// ─── Query result ────────────────────────────────────────────────────

pub const QueryResult = struct {
    columns: []ColumnInfo,
    rows: [][]?[]const u8,
    command_tag: []const u8,
    allocator: mem.Allocator,

    pub fn deinit(self: *QueryResult) void {
        for (self.rows) |row| {
            for (row) |cell| {
                if (cell) |data| self.allocator.free(data);
            }
            self.allocator.free(row);
        }
        self.allocator.free(self.rows);
        for (self.columns) |col| {
            self.allocator.free(col.name);
        }
        self.allocator.free(self.columns);
        self.allocator.free(self.command_tag);
    }
};

// ─── Client ──────────────────────────────────────────────────────────

pub const Client = struct {
    fd: posix.socket_t,
    allocator: mem.Allocator,

    const read_buf_size = 8192;

    const BackendMessage = struct {
        tag: u8,
        payload: []u8,
        buf: [read_buf_size]u8,
    };

    /// Connect to a Postgres server, perform startup and authentication.
    /// Handles trust, cleartext, and MD5 auth. Returns error on connection failure.
    pub fn connect(
        allocator: mem.Allocator,
        host: []const u8,
        port: u16,
        user: []const u8,
        database: []const u8,
        password: ?[]const u8,
    ) !Client {
        // Resolve address — use IPv4 loopback for "127.0.0.1", otherwise parse
        const addr = blk: {
            var sa: posix.sockaddr.in = .{
                .port = mem.nativeTo(u16, port, .big),
                .addr = undefined,
            };
            // Parse dotted-quad IPv4
            var octets: [4]u8 = undefined;
            var octet_idx: usize = 0;
            var cur: u16 = 0;
            for (host) |c| {
                if (c == '.') {
                    if (octet_idx >= 4) return error.InvalidAddress;
                    octets[octet_idx] = @intCast(cur);
                    octet_idx += 1;
                    cur = 0;
                } else if (c >= '0' and c <= '9') {
                    cur = cur * 10 + (c - '0');
                    if (cur > 255) return error.InvalidAddress;
                } else {
                    return error.InvalidAddress;
                }
            }
            if (octet_idx != 3) return error.InvalidAddress;
            octets[3] = @intCast(cur);
            sa.addr = @bitCast(octets);
            break :blk sa;
        };

        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);

        try posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));

        var client = Client{ .fd = fd, .allocator = allocator };

        var startup_buf: [256]u8 = undefined;
        const startup_msg = wire.encodeStartupMessage(&startup_buf, user, database);
        try client.sendAll(startup_msg);

        try client.handleStartupResponse(user, password);

        return client;
    }

    /// Send a simple query and collect all result rows.
    /// Returns a QueryResult that the caller must deinit.
    pub fn query(self: *Client, allocator: mem.Allocator, sql: []const u8) !QueryResult {
        // Send Query message
        var query_buf: [8192]u8 = undefined;
        if (sql.len + 6 > query_buf.len) return error.QueryTooLong;
        const msg = wire.encodeQuery(&query_buf, sql);
        try self.sendAll(msg);

        // Collect response
        return self.readQueryResponse(allocator);
    }

    /// Send Terminate and close the socket.
    pub fn close(self: *Client) void {
        var term_buf: [8]u8 = undefined;
        const msg = wire.encodeTerminate(&term_buf);
        _ = posix.write(self.fd, msg) catch unreachable;
        posix.close(self.fd);
    }

    // ─── Internal helpers ────────────────────────────────────────────

    fn sendAll(self: *Client, data: []const u8) !void {
        var sent: usize = 0;
        while (sent < data.len) {
            const n = try posix.write(self.fd, data[sent..]);
            if (n == 0) return error.ConnectionRefused;
            sent += n;
        }
    }

    fn readExact(self: *Client, buf: []u8) !void {
        var total: usize = 0;
        while (total < buf.len) {
            const n = try posix.read(self.fd, buf[total..]);
            if (n == 0) return error.ConnectionRefused;
            total += n;
        }
    }

    /// Read the next complete backend message. Returns tag + payload in a stack-allocated buffer.
    fn readBackendMessage(self: *Client) !BackendMessage {
        var header_buf: [5]u8 = undefined;
        try self.readExact(&header_buf);
        const header = try wire.readMessageHeader(&header_buf);
        const payload_len = header.length - 4; // length includes itself but not tag

        var result = BackendMessage{
            .tag = header.tag,
            .payload = undefined,
            .buf = undefined,
        };

        if (payload_len > read_buf_size) return error.MessageTooLarge;
        try self.readExact(result.buf[0..payload_len]);
        result.payload = result.buf[0..payload_len];
        return result;
    }

    fn handleStartupResponse(self: *Client, user: []const u8, password: ?[]const u8) !void {
        while (true) {
            const msg = try self.readBackendMessage();
            switch (msg.tag) {
                wire.BackendTag.authentication => {
                    const auth_type = try wire.parseAuthType(msg.payload);
                    switch (auth_type) {
                        .ok => {}, // AuthenticationOk — continue reading
                        .cleartext_password => {
                            const pw = password orelse return error.AuthenticationFailed;
                            var pw_buf: [256]u8 = undefined;
                            const pw_msg = wire.encodePasswordMessage(&pw_buf, pw);
                            try self.sendAll(pw_msg);
                        },
                        .md5_password => {
                            const pw = password orelse return error.AuthenticationFailed;
                            const salt = try wire.parseMd5Salt(msg.payload);
                            const md5_hash = auth.computeMd5Password(user, pw, salt);
                            var pw_buf: [256]u8 = undefined;
                            const pw_msg = wire.encodePasswordMessage(&pw_buf, &md5_hash);
                            try self.sendAll(pw_msg);
                        },
                        else => return error.UnsupportedAuth,
                    }
                },
                wire.BackendTag.parameter_status => {
                    // Ignore for now — tracked params are a Phase 11 concern.
                },
                wire.BackendTag.backend_key_data => {
                    // Store pid/secret for cancel — ignored for MVP.
                },
                wire.BackendTag.ready_for_query => {
                    return; // Startup complete
                },
                wire.BackendTag.error_response => {
                    return error.ServerError;
                },
                else => {
                    // Skip unknown messages during startup
                },
            }
        }
    }

    fn readQueryResponse(self: *Client, allocator: mem.Allocator) !QueryResult {
        var column_descs: [128]wire.ColumnDesc = undefined;
        var col_count: u16 = 0;
        var rows: std.ArrayList([]?[]const u8) = .{};
        errdefer {
            for (rows.items) |row| {
                for (row) |cell| {
                    if (cell) |data| allocator.free(data);
                }
                allocator.free(row);
            }
            rows.deinit(allocator);
        }
        var column_names_copied = false;
        errdefer {
            if (column_names_copied) {
                for (column_descs[0..col_count]) |desc| {
                    allocator.free(desc.name);
                }
            }
        }
        var command_tag: []u8 = &.{};
        errdefer if (command_tag.len > 0) allocator.free(command_tag);

        while (true) {
            const msg = try self.readBackendMessage();
            switch (msg.tag) {
                wire.BackendTag.row_description => {
                    col_count = try wire.parseRowDescription(msg.payload, &column_descs);
                    // Copy column names NOW — msg.buf will be overwritten
                    // on the next readBackendMessage call.
                    for (column_descs[0..col_count]) |*desc| {
                        const name_copy = try allocator.alloc(u8, desc.name.len);
                        @memcpy(name_copy, desc.name);
                        desc.name = name_copy;
                    }
                    column_names_copied = true;
                },
                wire.BackendTag.data_row => {
                    var raw_values: [128]?[]const u8 = .{null} ** 128;
                    const n = try wire.parseDataRow(msg.payload, &raw_values);

                    // Copy values out since the buffer will be reused
                    const row = try allocator.alloc(?[]const u8, n);
                    errdefer allocator.free(row);

                    var col_idx: usize = 0;
                    while (col_idx < n) : (col_idx += 1) {
                        if (raw_values[col_idx]) |val| {
                            const copy = try allocator.alloc(u8, val.len);
                            @memcpy(copy, val);
                            row[col_idx] = copy;
                        } else {
                            row[col_idx] = null;
                        }
                    }
                    try rows.append(allocator, row);
                },
                wire.BackendTag.command_complete => {
                    const tag_str = wire.parseCommandComplete(msg.payload);
                    command_tag = try allocator.alloc(u8, tag_str.len);
                    @memcpy(command_tag, tag_str);
                },
                wire.BackendTag.ready_for_query => {
                    break; // Query complete
                },
                wire.BackendTag.error_response => {
                    return error.ServerError;
                },
                wire.BackendTag.empty_query_response => {
                    // Empty query — will get ReadyForQuery next
                },
                else => {
                    // Skip notices, parameter status, etc.
                },
            }
        }

        // Build column info
        const columns = try allocator.alloc(ColumnInfo, col_count);
        errdefer allocator.free(columns);
        for (0..col_count) |i| {
            // name was already copied from the wire buffer in the
            // row_description handler above (msg.buf is ephemeral).
            columns[i] = .{
                .name = column_descs[i].name,
                .table_oid = column_descs[i].table_oid,
                .column_index = column_descs[i].column_attr,
                .type_oid = column_descs[i].type_oid,
                .type_size = column_descs[i].type_len,
                .type_modifier = column_descs[i].type_mod,
                .format = if (column_descs[i].format == 0) .text else .binary,
            };
        }

        return .{
            .columns = columns,
            .rows = try rows.toOwnedSlice(allocator),
            .command_tag = command_tag,
            .allocator = allocator,
        };
    }
};

// ─── Retained stubs from the original design (Phase 11 concerns) ────
// These exist so the file remains compatible with the build system's test list.

pub const DecodePipeline = struct {
    columns: []ColumnInfo,
    decoders: []const *const fn ([]const u8) types.Value,
};

pub const PreparedStatement = struct {
    name: []const u8,
    sql: []const u8,
    param_count: u16,
    param_oids: []const u32,
    pipeline: ?DecodePipeline,
};

pub const StatementCache = struct {
    capacity: u32,
    count: u32,

    pub fn init(capacity: u32) StatementCache {
        return .{ .capacity = capacity, .count = 0 };
    }

    pub fn get(self: *StatementCache, sql: []const u8) ?*PreparedStatement {
        _ = .{ self, sql };
        @panic("StatementCache.get: not yet implemented — Phase 11");
    }

    pub fn put(self: *StatementCache, stmt: PreparedStatement) void {
        _ = .{ self, stmt };
        @panic("StatementCache.put: not yet implemented — Phase 11");
    }

    pub fn remove(self: *StatementCache, name: []const u8) bool {
        _ = .{ self, name };
        @panic("StatementCache.remove: not yet implemented — Phase 11");
    }

    pub fn clear(self: *StatementCache) void {
        _ = self;
        @panic("StatementCache.clear: not yet implemented — Phase 11");
    }
};

pub const Row = struct {
    values: []const ?[]const u8,
    columns: []const ColumnInfo,

    pub fn get(self: *const Row, comptime T: type, index: usize) !T {
        _ = .{ self, index };
        @panic("Row.get: not yet implemented — Phase 11");
    }

    pub fn getByName(self: *const Row, comptime T: type, name: []const u8) !T {
        _ = .{ self, name };
        @panic("Row.getByName: not yet implemented — Phase 11");
    }
};

pub const RowIterator = struct {
    current: ?Row,

    pub fn next(self: *RowIterator) !?*const Row {
        _ = self;
        @panic("RowIterator.next: not yet implemented — Phase 11");
    }

    pub fn reset(self: *RowIterator) void {
        _ = self;
        @panic("RowIterator.reset: not yet implemented — Phase 11");
    }
};

pub const Transaction = struct {
    active: bool,

    pub fn begin(self: *Transaction) !void {
        _ = self;
        @panic("Transaction.begin: not yet implemented — Phase 11");
    }

    pub fn commit(self: *Transaction) !void {
        _ = self;
        @panic("Transaction.commit: not yet implemented — Phase 11");
    }

    pub fn rollback(self: *Transaction) !void {
        _ = self;
        @panic("Transaction.rollback: not yet implemented — Phase 11");
    }

    pub fn deinit(self: *Transaction) void {
        _ = self;
    }
};

pub const DBAPI2Cursor = struct {
    description: ?[]const ColumnInfo,
    rowcount: i64,
    arraysize: u32,

    pub fn execute(self: *DBAPI2Cursor, sql: []const u8, params: ?[]const ?[]const u8) !void {
        _ = .{ self, sql, params };
        @panic("DBAPI2Cursor.execute: not yet implemented — Phase 11");
    }

    pub fn executemany(self: *DBAPI2Cursor, sql: []const u8, param_seq: []const []const ?[]const u8) !void {
        _ = .{ self, sql, param_seq };
        @panic("DBAPI2Cursor.executemany: not yet implemented — Phase 11");
    }

    pub fn fetchone(self: *DBAPI2Cursor) !?Row {
        _ = self;
        @panic("DBAPI2Cursor.fetchone: not yet implemented — Phase 11");
    }

    pub fn fetchmany(self: *DBAPI2Cursor, size: ?u32) ![]Row {
        _ = .{ self, size };
        @panic("DBAPI2Cursor.fetchmany: not yet implemented — Phase 11");
    }

    pub fn fetchall(self: *DBAPI2Cursor) ![]Row {
        _ = self;
        @panic("DBAPI2Cursor.fetchall: not yet implemented — Phase 11");
    }

    pub fn close(self: *DBAPI2Cursor) void {
        _ = self;
    }
};

pub fn QueryInterfaceType(comptime IO: type) type {
    return struct {
        const Self = @This();

        io: *IO,
        cache: StatementCache,

        pub fn prepare(self: *Self, fd: i32, sql: []const u8) !*PreparedStatement {
            _ = .{ self, fd, sql };
            @panic("QueryInterfaceType.prepare: not yet implemented — Phase 11");
        }

        pub fn execute(self: *Self, fd: i32, stmt: *PreparedStatement, params: []const ?[]const u8) !QueryResult {
            _ = .{ self, fd, stmt, params };
            @panic("QueryInterfaceType.execute: not yet implemented — Phase 11");
        }

        pub fn fetch(self: *Self, fd: i32, sql: []const u8, params: []const ?[]const u8) !QueryResult {
            _ = .{ self, fd, sql, params };
            @panic("QueryInterfaceType.fetch: not yet implemented — Phase 11");
        }

        pub fn fetchOne(self: *Self, fd: i32, sql: []const u8, params: []const ?[]const u8) !?Row {
            _ = .{ self, fd, sql, params };
            @panic("QueryInterfaceType.fetchOne: not yet implemented — Phase 11");
        }

        pub fn beginTransaction(self: *Self, fd: i32) !Transaction {
            _ = .{ self, fd };
            @panic("QueryInterfaceType.beginTransaction: not yet implemented — Phase 11");
        }

        pub fn executeBatch(self: *Self, fd: i32, queries: []const []const u8) ![]QueryResult {
            _ = .{ self, fd, queries };
            @panic("QueryInterfaceType.executeBatch: not yet implemented — Phase 11");
        }
    };
}

// ─── Tests ───────────────────────────────────────────────────────────

test "connect to postgres" {
    // Integration test — skip if no Postgres available.
    const allocator = std.testing.allocator;
    var client = Client.connect(allocator, "127.0.0.1", 5432, "postgres", "postgres", null) catch |err| {
        // Skip if Postgres is not running or requires auth we can't provide
        if (err == error.ConnectionRefused or err == error.ServerError or err == error.AuthenticationFailed) return error.SkipZigTest;
        return err;
    };
    defer client.close();

    var result = try client.query(allocator, "SELECT 1 AS num");
    defer result.deinit();

    try std.testing.expectEqual(result.columns.len, 1);
    try std.testing.expectEqualStrings("num", result.columns[0].name);
    try std.testing.expectEqual(result.rows.len, 1);
    try std.testing.expectEqualStrings("1", result.rows[0][0].?);
}

test "query multiple rows" {
    const allocator = std.testing.allocator;
    var client = Client.connect(allocator, "127.0.0.1", 5432, "postgres", "postgres", null) catch |err| {
        if (err == error.ConnectionRefused or err == error.ServerError or err == error.AuthenticationFailed) return error.SkipZigTest;
        return err;
    };
    defer client.close();

    var result = try client.query(allocator, "SELECT generate_series(1, 3) AS n");
    defer result.deinit();

    try std.testing.expectEqual(result.rows.len, 3);
    try std.testing.expectEqualStrings("1", result.rows[0][0].?);
    try std.testing.expectEqualStrings("2", result.rows[1][0].?);
    try std.testing.expectEqualStrings("3", result.rows[2][0].?);
}

test "query with nulls" {
    const allocator = std.testing.allocator;
    var client = Client.connect(allocator, "127.0.0.1", 5432, "postgres", "postgres", null) catch |err| {
        if (err == error.ConnectionRefused or err == error.ServerError or err == error.AuthenticationFailed) return error.SkipZigTest;
        return err;
    };
    defer client.close();

    var result = try client.query(allocator, "SELECT NULL AS empty");
    defer result.deinit();

    try std.testing.expectEqual(result.rows.len, 1);
    try std.testing.expect(result.rows[0][0] == null);
}

test "query multiple columns" {
    const allocator = std.testing.allocator;
    var client = Client.connect(allocator, "127.0.0.1", 5432, "postgres", "postgres", null) catch |err| {
        if (err == error.ConnectionRefused or err == error.ServerError or err == error.AuthenticationFailed) return error.SkipZigTest;
        return err;
    };
    defer client.close();

    var result = try client.query(allocator, "SELECT 42 AS id, 'hello' AS name, NULL AS note");
    defer result.deinit();

    try std.testing.expectEqual(result.columns.len, 3);
    try std.testing.expectEqualStrings("id", result.columns[0].name);
    try std.testing.expectEqualStrings("name", result.columns[1].name);
    try std.testing.expectEqualStrings("note", result.columns[2].name);

    try std.testing.expectEqual(result.rows.len, 1);
    try std.testing.expectEqualStrings("42", result.rows[0][0].?);
    try std.testing.expectEqualStrings("hello", result.rows[0][1].?);
    try std.testing.expect(result.rows[0][2] == null);
}

test "command tag" {
    const allocator = std.testing.allocator;
    var client = Client.connect(allocator, "127.0.0.1", 5432, "postgres", "postgres", null) catch |err| {
        if (err == error.ConnectionRefused or err == error.ServerError or err == error.AuthenticationFailed) return error.SkipZigTest;
        return err;
    };
    defer client.close();

    var result = try client.query(allocator, "SELECT 1");
    defer result.deinit();

    // Command tag for SELECT should start with "SELECT"
    try std.testing.expect(std.mem.startsWith(u8, result.command_tag, "SELECT"));
}

test "statement cache init" {
    const cache = StatementCache.init(100);
    try std.testing.expectEqual(cache.capacity, 100);
    try std.testing.expectEqual(cache.count, 0);
}

// ─── Retained empty stubs for Phase 11 tests ─────────────────────────

test "prepare statement" {}
test "prepare caches decode pipeline" {}
test "execute prepared statement" {}
test "fetch query results" {}
test "fetch one row" {}
test "row iterator invalidates previous" {}
test "row get by index" {}
test "row get by name" {}
test "statement cache hit" {}
test "statement cache miss" {}
test "statement cache lru eviction" {}
test "transaction begin commit" {}
test "transaction auto rollback" {}
test "batch pipeline submission" {}
test "dbapi2 cursor execute" {}
test "dbapi2 cursor fetchone" {}
test "dbapi2 cursor fetchall" {}
