//! Single Redis connection: connect, authenticate, command, pipeline.
//! Generic-over-IO for simulation testing.

const std = @import("std");
const protocol = @import("protocol.zig");

pub const ConnectionConfig = struct {
    host: []const u8,
    port: u16 = 6379,
    password: ?[]const u8 = null,
    username: ?[]const u8 = null,
    db: u8 = 0,
    timeout_ms: u32 = 5_000,
};

pub fn RedisConnection(comptime IO: type) type {
    return struct {
        const Self = @This();

        io: *IO,
        config: ConnectionConfig,
        fd: i32,
        connected: bool,
        resp_version: u8,

        /// Connect to a Redis server.
        pub fn connect(io: *IO, config: ConnectionConfig) !Self {
            _ = .{ io, config };
            return undefined;
        }

        /// Disconnect and close the socket.
        pub fn disconnect(self: *Self) void {
            _ = .{self};
        }

        /// Authenticate with AUTH command (RESP3: supports username+password).
        pub fn authenticate(self: *Self) !void {
            _ = .{self};
        }

        /// Switch to RESP3 protocol via HELLO 3.
        pub fn hello(self: *Self) !void {
            _ = .{self};
        }

        /// Select a database.
        pub fn selectDb(self: *Self, db: u8) !void {
            _ = .{ self, db };
        }

        /// Send a command and read the response.
        pub fn sendCommand(self: *Self, args: []const []const u8) !protocol.RespValue {
            _ = .{ self, args };
            return undefined;
        }

        /// Read a single RESP3 response from the connection.
        pub fn readResponse(self: *Self) !protocol.RespValue {
            _ = .{self};
            return undefined;
        }

        /// Pipeline: batch multiple commands, flush, then read all responses.
        pub fn pipeline(self: *Self, commands: []const []const []const u8) ![]const protocol.RespValue {
            _ = .{ self, commands };
            return undefined;
        }

        /// Flush all pending pipeline commands to the server.
        pub fn flushPipeline(self: *Self) !void {
            _ = .{self};
        }

        /// PING for health checking.
        pub fn ping(self: *Self) !bool {
            _ = .{self};
            return undefined;
        }
    };
}

test "connect and authenticate" {}

test "send command" {}

test "pipeline commands" {}

test "RESP3 hello" {}

test "ping health check" {}
