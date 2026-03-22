//! Single Redis connection: connect over TCP, send RESP3 commands, read responses.
//! Uses std.posix for blocking TCP (no io_uring dependency for now).

const std = @import("std");
const protocol = @import("protocol.zig");

/// Owns both the decoded value and the backing buffer that string slices point into.
/// String slices in the RespValue point into raw_buf, so raw_buf must outlive
/// any use of the value's string fields.
pub const Response = struct {
    value: protocol.RespValue,
    /// The raw response bytes. String slices in .value point into this buffer.
    raw_buf: []u8,
    /// How many bytes of raw_buf are response data (rest is unused capacity).
    raw_len: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        protocol.freeValue(self.allocator, self.value);
        self.allocator.free(self.raw_buf);
    }
};

pub const Client = struct {
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
    read_buf: [4096]u8 = undefined,

    /// Connect to a Redis server at host:port.
    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) !Client {
        const address = try std.net.Address.parseIp4(host, port);
        const stream = try std.net.tcpConnectToAddress(address);

        return Client{
            .stream = stream,
            .allocator = allocator,
        };
    }

    /// Send a command and read the response.
    /// Caller must call .deinit() on the returned Response when done.
    pub fn command(self: *Client, args: []const []const u8) !Response {
        // Encode the command.
        const encoded = try protocol.encode(self.allocator, args);
        defer self.allocator.free(encoded);

        // Write the command to the socket.
        var written: usize = 0;
        while (written < encoded.len) {
            written += try self.stream.write(encoded[written..]);
        }

        // Read the response. Accumulate data until we have a complete frame.
        var response_buf: std.ArrayList(u8) = .{};
        errdefer response_buf.deinit(self.allocator);

        while (true) {
            const n = try self.stream.read(&self.read_buf);
            if (n == 0) return error.ConnectionClosed;
            try response_buf.appendSlice(self.allocator, self.read_buf[0..n]);

            // Try to decode. If incomplete, read more.
            const result = protocol.decode(self.allocator, response_buf.items) catch |err| {
                if (err == error.Incomplete) continue;
                return err;
            };

            // Transfer ownership of the ArrayList's internal buffer to the Response.
            // The decoded value's string slices point into response_buf.items,
            // which is the same memory as the allocatedSlice. We hand that memory
            // to Response so it stays valid.
            const alloc_slice = response_buf.allocatedSlice();
            // Disown from ArrayList so deinit won't free it.
            response_buf.items = &.{};
            response_buf.capacity = 0;

            return Response{
                .value = result.value,
                .raw_buf = alloc_slice,
                .raw_len = result.consumed,
                .allocator = self.allocator,
            };
        }
    }

    /// Close the connection.
    pub fn close(self: *Client) void {
        self.stream.close();
    }
};

// ============================================================================
// Tests -- unit tests that don't need a Redis server
// ============================================================================

test "Client struct is well-formed" {
    const info = @typeInfo(Client);
    try std.testing.expect(info == .@"struct");
}

// ============================================================================
// Integration tests -- gated on Redis being available
// ============================================================================

test "ping redis" {
    const allocator = std.testing.allocator;
    var client = Client.connect(allocator, "127.0.0.1", 6379) catch |err| {
        if (err == error.ConnectionRefused) return error.SkipZigTest;
        return err;
    };
    defer client.close();

    const args = [_][]const u8{"PING"};
    var result = try client.command(&args);
    defer result.deinit();

    // Redis replies to PING with +PONG\r\n
    try std.testing.expectEqualStrings("PONG", result.value.simple_string);
}

test "set and get" {
    const allocator = std.testing.allocator;
    var client = Client.connect(allocator, "127.0.0.1", 6379) catch |err| {
        if (err == error.ConnectionRefused) return error.SkipZigTest;
        return err;
    };
    defer client.close();

    // SET
    const set_args = [_][]const u8{ "SET", "snek:test:key", "hello_snek" };
    var set_result = try client.command(&set_args);
    defer set_result.deinit();
    try std.testing.expectEqualStrings("OK", set_result.value.simple_string);

    // GET
    const get_args = [_][]const u8{ "GET", "snek:test:key" };
    var get_result = try client.command(&get_args);
    defer get_result.deinit();
    try std.testing.expectEqualStrings("hello_snek", get_result.value.bulk_string);

    // DEL (cleanup)
    const del_args = [_][]const u8{ "DEL", "snek:test:key" };
    var del_result = try client.command(&del_args);
    defer del_result.deinit();
    try std.testing.expect(del_result.value.integer >= 1);
}

test "get nonexistent key returns null" {
    const allocator = std.testing.allocator;
    var client = Client.connect(allocator, "127.0.0.1", 6379) catch |err| {
        if (err == error.ConnectionRefused) return error.SkipZigTest;
        return err;
    };
    defer client.close();

    const args = [_][]const u8{ "GET", "snek:test:nonexistent_key_xyz" };
    var result = try client.command(&args);
    defer result.deinit();
    try std.testing.expectEqual(protocol.RespValue{ .null_value = {} }, result.value);
}
