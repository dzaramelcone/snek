//! Pipeline mode: up to 71x speedup on high-latency networks.
//!
//! Two-queue pattern: dispatched_queue (sent to server, awaiting response)
//! and pending_queue (buffered, not yet sent).
//! Sync message handling for error recovery boundaries.
//!
//! Generic-over-IO.
//!
//! Sources:
//!   - Two-queue pattern (pending + dispatched): see src/db/REFERENCES.md.
//!     Pipeline mode sends multiple extended-query sequences before reading any responses,
//!     achieving up to 71x speedup on high-latency networks.
//!   - PostgreSQL pipeline mode protocol: https://www.postgresql.org/docs/current/libpq-pipeline-mode.html
//!   - Generic-over-IO: TigerBeetle pattern.

const std = @import("std");
const wire = @import("wire.zig");
const query = @import("query.zig");

// ─── Pipeline entry ──────────────────────────────────────────────────

pub const PipelineEntryKind = enum {
    parse,
    bind,
    execute,
    sync,
};

pub const PipelineEntry = struct {
    kind: PipelineEntryKind,
    statement_name: []const u8,
    portal_name: []const u8,
    sql: []const u8,
    params: ?[]const ?[]const u8,
    max_rows: u32,
};

// ─── Pipeline result ─────────────────────────────────────────────────

pub const PipelineResultStatus = enum {
    ok,
    error_at_sync,
    connection_lost,
};

pub const PipelineResult = struct {
    status: PipelineResultStatus,
    results: []query.QueryResult,
    error_index: ?usize,
    error_notice: ?wire.ErrorNotice,
};

// ─── Pipeline (Generic-over-IO) ──────────────────────────────────────

pub fn PipelineType(comptime IO: type) type {
    return struct {
        const Self = @This();

        io: *IO,
        fd: i32,
        pending_count: u32,
        dispatched_count: u32,

        /// Initialize a pipeline on a connection.
        pub fn init(io: *IO, fd: i32) Self {
            _ = .{ io, fd };
            return undefined;
        }

        /// Add a Parse message to the pending queue.
        pub fn addParse(self: *Self, name: []const u8, sql: []const u8, param_oids: []const u32) !void {
            _ = .{ self, name, sql, param_oids };
        }

        /// Add a Bind message to the pending queue.
        pub fn addBind(self: *Self, portal: []const u8, statement: []const u8, params: []const ?[]const u8, format_codes: []const u16) !void {
            _ = .{ self, portal, statement, params, format_codes };
        }

        /// Add an Execute message to the pending queue.
        pub fn addExecute(self: *Self, portal: []const u8, max_rows: u32) !void {
            _ = .{ self, portal, max_rows };
        }

        /// Add a Sync message (error recovery boundary).
        /// Sync acts as a transaction fence — server discards commands after an error
        /// until the next Sync. See PostgreSQL protocol docs on pipeline error handling.
        pub fn addSync(self: *Self) !void {
            _ = .{self};
        }

        /// Flush all pending messages to the server.
        /// Moves entries from pending_queue to dispatched_queue.
        /// Two-queue pattern: pending → dispatched on flush. See src/db/REFERENCES.md.
        pub fn flush(self: *Self) !void {
            _ = .{self};
        }

        /// Drain all dispatched responses from the server.
        /// Collects results up to the next Sync/ReadyForQuery.
        pub fn drain(self: *Self) !PipelineResult {
            _ = .{self};
            return undefined;
        }

        /// Convenience: add Parse + Bind + Execute for a single query.
        pub fn addQuery(self: *Self, sql: []const u8, params: []const ?[]const u8) !void {
            _ = .{ self, sql, params };
        }

        /// Convenience: flush + drain all.
        pub fn execute(self: *Self) !PipelineResult {
            _ = .{self};
            return undefined;
        }

        /// Reset pipeline state after error recovery.
        pub fn reset(self: *Self) void {
            _ = .{self};
        }
    };
}

test "pipeline add parse" {}

test "pipeline add bind" {}

test "pipeline add execute" {}

test "pipeline add sync" {}

test "pipeline flush" {}

test "pipeline drain" {}

test "pipeline three queries" {}

test "pipeline error recovery at sync boundary" {}

test "pipeline convenience add query" {}

test "pipeline convenience execute" {}

test "pipeline reset after error" {}
