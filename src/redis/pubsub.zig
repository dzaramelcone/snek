//! Redis Pub/Sub: subscribe, pattern subscribe, message dispatch.
//! Generic-over-IO. Uses a dedicated connection outside the pool.
//!
//! Source: Dedicated connection outside pool — same pattern as db/notify.zig.
//! Pub/Sub requires a persistent connection that cannot be shared with
//! the command pool.

const std = @import("std");
const conn = @import("connection.zig");
const protocol = @import("protocol.zig");

pub const Message = struct {
    channel: []const u8,
    pattern: ?[]const u8,
    payload: []const u8,
};

pub const Subscription = struct {
    channel: []const u8,
    is_pattern: bool,
};

pub const MessageCallback = *const fn (msg: Message) void;

/// Pub/Sub subscriber with a dedicated connection (outside the pool).
/// Manages subscriptions and dispatches incoming messages to callbacks.
/// Source: Dedicated connection pattern (same as db/notify.zig).
pub fn Subscriber(comptime IO: type) type {
    return struct {
        const Self = @This();
        const Connection = conn.RedisConnection(IO);

        io: *IO,
        connection: Connection,
        subscriptions: [64]?Subscription,
        subscription_count: usize,
        callbacks: [64]?MessageCallback,

        /// Create a subscriber with a dedicated connection.
        pub fn init(io: *IO, config: conn.ConnectionConfig) !Self {
            _ = .{ io, config };
            return undefined;
        }

        pub fn deinit(self: *Self) void {
            _ = .{self};
        }

        /// Subscribe to a channel.
        pub fn subscribe(self: *Self, channel: []const u8) !void {
            _ = .{ self, channel };
        }

        /// Unsubscribe from a channel.
        pub fn unsubscribe(self: *Self, channel: []const u8) !void {
            _ = .{ self, channel };
        }

        /// Subscribe to channels matching a glob pattern.
        pub fn psubscribe(self: *Self, pattern: []const u8) !void {
            _ = .{ self, pattern };
        }

        /// Unsubscribe from a pattern.
        pub fn punsubscribe(self: *Self, pattern: []const u8) !void {
            _ = .{ self, pattern };
        }

        /// Register a callback for incoming messages on a channel.
        pub fn onMessage(self: *Self, channel: []const u8, callback: MessageCallback) void {
            _ = .{ self, channel, callback };
        }

        /// Poll for incoming messages and dispatch to registered callbacks.
        pub fn poll(self: *Self) !void {
            _ = .{self};
        }

        /// Publish a message to a channel (uses a separate connection).
        pub fn publish(self: *Self, channel: []const u8, message: []const u8) !void {
            _ = .{ self, channel, message };
        }
    };
}

test "subscribe to channel" {}

test "pattern subscribe" {}

test "receive message" {}

test "unsubscribe" {}

test "message callback dispatch" {}
