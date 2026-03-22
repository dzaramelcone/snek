//! LISTEN/NOTIFY support: dedicated connection outside pool,
//! channel subscriptions, fan-out to registered handlers.
//!
//! Brandur's Notifier pattern: buffered non-blocking sends, drop on overflow.
//!
//! Generic-over-IO.
//!
//! Sources:
//!   - Brandur's Notifier pattern: dedicated connection outside the pool, buffered
//!     non-blocking sends, drop notifications on overflow rather than blocking.
//!     See docs/GAPS_RESEARCH.md.
//!   - PostgreSQL LISTEN/NOTIFY: https://www.postgresql.org/docs/current/sql-notify.html

const std = @import("std");
const wire = @import("wire.zig");

// ─── Notification (re-exported from wire for convenience) ────────────

pub const Notification = wire.Notification;

// ─── Handler function type ───────────────────────────────────────────

pub const NotifyHandler = *const fn (notification: Notification) void;

// ─── Channel subscription ────────────────────────────────────────────

pub const Subscription = struct {
    channel: []const u8,
    handler: NotifyHandler,
};

// ─── Notifier config ─────────────────────────────────────────────────

pub const NotifyConfig = struct {
    /// Max buffered notifications before dropping (Brandur's pattern).
    buffer_capacity: u32,
    /// Reconnect delay on connection loss.
    reconnect_delay_ms: u32,
};

// ─── NotifyListener (Generic-over-IO) ────────────────────────────────

pub fn NotifyListenerType(comptime IO: type) type {
    return struct {
        const Self = @This();

        io: *IO,
        fd: i32,
        config: NotifyConfig,
        subscription_count: u32,
        buffer_count: u32,
        dropped_count: u64,

        /// Initialize a dedicated LISTEN connection (outside pool).
        /// Source: Brandur's pattern — LISTEN connection must not be pooled
        /// because notifications are connection-scoped. See docs/GAPS_RESEARCH.md.
        pub fn init(io: *IO, fd: i32, config: NotifyConfig) Self {
            _ = .{ io, fd, config };
            return undefined;
        }

        /// Subscribe to a channel. Sends LISTEN command.
        pub fn subscribe(self: *Self, channel: []const u8, handler: NotifyHandler) !void {
            _ = .{ self, channel, handler };
        }

        /// Unsubscribe from a channel. Sends UNLISTEN command.
        pub fn unsubscribe(self: *Self, channel: []const u8) !void {
            _ = .{ self, channel };
        }

        /// Poll for incoming notifications. Non-blocking.
        /// Dispatches to registered handlers via fan-out.
        pub fn poll(self: *Self) !void {
            _ = .{self};
        }

        /// Fan-out a notification to all handlers registered for that channel.
        /// Buffered non-blocking: drops notification if buffer full.
        /// Source: Brandur's Notifier — drop on overflow to preserve liveness.
        /// See docs/GAPS_RESEARCH.md.
        pub fn dispatch(self: *Self, notification: Notification) void {
            _ = .{ self, notification };
        }

        /// Get the number of dropped notifications (overflow counter).
        pub fn droppedCount(self: *const Self) u64 {
            return self.dropped_count;
        }

        /// Close the dedicated LISTEN connection.
        pub fn deinit(self: *Self) void {
            _ = .{self};
        }
    };
}

test "subscribe to channel" {}

test "unsubscribe from channel" {}

test "receive notification" {}

test "fan-out to multiple handlers" {}

test "overflow handling drops notifications" {}

test "dropped count tracking" {}

test "reconnect on connection loss" {}
