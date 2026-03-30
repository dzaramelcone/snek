//! Prepared statement cache for the extended query protocol.
//!
//! Maps SQL strings to statement names ("s0", "s1", ...) and caches
//! RowDescription column metadata from the first Describe response.
//! Prepare-on-first-use: first query sends Parse+Describe+Bind+Execute+Sync,
//! subsequent queries send Bind+Execute+Sync (skipping SQL parsing on server).

const std = @import("std");
const wire = @import("wire.zig");
const ffi = @import("../python/ffi.zig");
const snek_row = @import("../python/snek_row.zig");

pub const MAX_STMTS = 128;
pub const MAX_COLS = 64;

pub const Entry = struct {
    sql_hash: u64,
    col_count: u16 = 0,
    described: bool = false, // true once RowDescription/NoData received
    // Cached Python string objects for column names — created once, reused per row
    col_keys: [MAX_COLS]?*ffi.PyObject = .{null} ** MAX_COLS,
    // Per-column serialization strategy (derived from type_oid)
    col_strategies: [MAX_COLS]snek_row.SerializeStrategy = .{.text_escape} ** MAX_COLS,
    // Precomputed JSON key fragments: `{"col":` and `,{"col":`
    json_keys: [2048]u8 = undefined,
    json_key_offsets: [MAX_COLS + 1]u16 = .{0} ** (MAX_COLS + 1),
    json_keys_built: bool = false,
    // Pre-built Bind+Execute+Sync bytes for the no-param case
    bind_template: [128]u8 = undefined,
    bind_template_len: u16 = 0,
    bind_template_built: bool = false,

    /// Build JSON key fragments from cached Python column name objects.
    /// Call once after col_keys are populated.
    pub fn buildJsonKeys(self: *Entry) void {
        if (self.json_keys_built) return;
        var pos: u16 = 0;
        for (0..self.col_count) |i| {
            self.json_key_offsets[i] = pos;
            const key = self.col_keys[i] orelse continue;
            const key_str = ffi.unicodeAsUTF8(key) catch continue;
            const key_span = std.mem.span(key_str);

            // Write `{"name":` or `,"name":`
            const prefix: u8 = if (i == 0) '{' else ',';
            if (pos + 1 + 1 + key_span.len + 2 > self.json_keys.len) break;
            self.json_keys[pos] = prefix;
            self.json_keys[pos + 1] = '"';
            @memcpy(self.json_keys[pos + 2 ..][0..key_span.len], key_span);
            self.json_keys[pos + 2 + key_span.len] = '"';
            self.json_keys[pos + 2 + key_span.len + 1] = ':';
            pos += @intCast(2 + key_span.len + 2);
        }
        self.json_key_offsets[self.col_count] = pos;
        self.json_keys_built = true;
    }

    /// Pre-build the Bind+Execute+Sync message sequence for zero-param queries.
    /// Called once per statement after first prepare on a connection.
    pub fn buildBindTemplate(self: *Entry, stmt_name: []const u8) void {
        var pos: usize = 0;
        const bind = wire.encodeBindWithParams(self.bind_template[pos..], stmt_name, &.{});
        pos += bind.len;
        const exec = wire.encodeExecute(self.bind_template[pos..]);
        pos += exec.len;
        const sync = wire.encodeSync(self.bind_template[pos..]);
        pos += sync.len;
        self.bind_template_len = @intCast(pos);
        self.bind_template_built = true;
    }
};

pub const HASH_SLOTS = 256; // power of 2, >= 2*MAX_STMTS for low collision rate
const EMPTY_SLOT: u16 = 0xFFFF;

pub const StmtCache = struct {
    entries: [MAX_STMTS]Entry = undefined,
    len: u16 = 0,
    hash_slots: [HASH_SLOTS]u16 = .{EMPTY_SLOT} ** HASH_SLOTS,

    /// Look up a statement by SQL hash. O(1) amortized via open-addressing hash table.
    pub fn lookup(self: *const StmtCache, sql_hash: u64) ?u16 {
        var slot: u8 = @truncate(sql_hash);
        while (true) {
            const idx = self.hash_slots[slot];
            if (idx == EMPTY_SLOT) return null;
            if (self.entries[idx].sql_hash == sql_hash) return idx;
            slot +%= 1;
        }
    }

    /// Insert a new statement. Returns index.
    pub fn insert(self: *StmtCache, sql_hash: u64) !u16 {
        if (self.len >= MAX_STMTS) return error.StmtCacheFull;
        const idx = self.len;
        self.entries[idx] = .{ .sql_hash = sql_hash };
        self.len += 1;

        // Insert into hash table
        var slot: u8 = @truncate(sql_hash);
        while (self.hash_slots[slot] != EMPTY_SLOT) {
            slot +%= 1;
        }
        self.hash_slots[slot] = idx;

        return idx;
    }

    /// Get a mutable entry by index.
    pub fn get(self: *StmtCache, idx: u16) *Entry {
        return &self.entries[idx];
    }

    /// Format statement name into buffer: "s0", "s1", etc.
    pub fn stmtName(idx: u16, buf: *[8]u8) []const u8 {
        return std.fmt.bufPrint(buf, "s{d}", .{idx}) catch buf[0..2];
    }

    /// Write extended protocol messages for a query into buf.
    /// Returns bytes written.
    /// If the statement is cached (already prepared), writes Bind+Execute+Sync.
    /// If uncached, writes Parse+Describe+Bind+Execute+Sync and inserts into cache.
    /// Encode extended protocol messages. `conn_prepared` is a per-connection
    /// bitset tracking which statements have been prepared on that connection.
    pub const MAX_PARAMS = 16;

    pub fn encodeExtended(self: *StmtCache, buf: []u8, sql: []const u8, conn_prepared: *[MAX_STMTS]bool) !struct { bytes_written: usize, stmt_idx: u16 } {
        return self.encodeExtendedWithParams(buf, sql, conn_prepared, &.{});
    }

    pub fn encodeExtendedWithParams(
        self: *StmtCache,
        buf: []u8,
        sql: []const u8,
        conn_prepared: *[MAX_STMTS]bool,
        params: []const ?[]const u8,
    ) !struct { bytes_written: usize, stmt_idx: u16 } {
        const sql_hash = std.hash.Wyhash.hash(0, sql);
        var pos: usize = 0;
        var name_buf: [8]u8 = undefined;

        const idx = if (self.lookup(sql_hash)) |i| i else try self.insert(sql_hash);
        const name = stmtName(idx, &name_buf);

        if (!conn_prepared[idx]) {
            // First use on this connection — Parse + Describe
            const parse = wire.encodeParse(buf[pos..], name, sql);
            pos += parse.len;
            if (!self.entries[idx].described) {
                const desc = wire.encodeDescribe(buf[pos..], 'S', name);
                pos += desc.len;
            }
            conn_prepared[idx] = true;
            if (!self.entries[idx].bind_template_built) {
                self.entries[idx].buildBindTemplate(name);
            }
        }

        // Bind + Execute + Sync — use pre-built template for zero-param case
        if (params.len == 0 and self.entries[idx].bind_template_built) {
            const tlen = self.entries[idx].bind_template_len;
            @memcpy(buf[pos..][0..tlen], self.entries[idx].bind_template[0..tlen]);
            pos += tlen;
        } else {
            const bind = wire.encodeBindWithParams(buf[pos..], name, params);
            pos += bind.len;
            const exec = wire.encodeExecute(buf[pos..]);
            pos += exec.len;
            const sync = wire.encodeSync(buf[pos..]);
            pos += sync.len;
        }
        return .{ .bytes_written = pos, .stmt_idx = idx };
    }
};
