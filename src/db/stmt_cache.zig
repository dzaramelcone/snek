//! Prepared statement cache for the extended query protocol.
//!
//! Maps SQL strings to statement names ("s0", "s1", ...) and caches
//! RowDescription column metadata from the first Describe response.
//! Prepare-on-first-use: first query sends Parse+Describe+Bind+Execute+Sync,
//! subsequent queries send Bind+Execute+Sync (skipping SQL parsing on server).

const std = @import("std");
const wire = @import("wire.zig");
const ffi = @import("../python/ffi.zig");

pub const MAX_STMTS = 128;

pub const Entry = struct {
    sql_hash: u64,
    col_descs: [64]wire.ColumnDesc = undefined,
    col_count: u16 = 0,
    described: bool = false, // true once RowDescription/NoData received
    // Cached Python string objects for column names — created once, reused per row
    col_keys: [64]?*ffi.PyObject = .{null} ** 64,
    keys_cached: bool = false,
};

pub const StmtCache = struct {
    entries: [MAX_STMTS]Entry = undefined,
    len: u16 = 0,

    /// Look up a statement by SQL hash. Returns index if found.
    pub fn lookup(self: *const StmtCache, sql_hash: u64) ?u16 {
        for (0..self.len) |i| {
            if (self.entries[i].sql_hash == sql_hash) return @intCast(i);
        }
        return null;
    }

    /// Insert a new statement. Returns index.
    pub fn insert(self: *StmtCache, sql_hash: u64) !u16 {
        if (self.len >= MAX_STMTS) return error.StmtCacheFull;
        const idx = self.len;
        self.entries[idx] = .{ .sql_hash = sql_hash };
        self.len += 1;
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
    pub fn encodeExtended(self: *StmtCache, buf: []u8, sql: []const u8, conn_prepared: *[MAX_STMTS]bool) !struct { bytes_written: usize, stmt_idx: u16 } {
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
        }

        // Always: Bind + Execute + Sync
        const bind = wire.encodeBind(buf[pos..], name);
        pos += bind.len;
        const exec = wire.encodeExecute(buf[pos..]);
        pos += exec.len;
        const sync = wire.encodeSync(buf[pos..]);
        pos += sync.len;
        return .{ .bytes_written = pos, .stmt_idx = idx };
    }
};
