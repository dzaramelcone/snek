//! Accept state machine — one per thread, spawns connections.

const std = @import("std");
const io = @import("io.zig");
const Socket = @import("socket.zig").Socket;
const Connection = @import("connection.zig").Connection;

pub const Acceptor = struct {
    listen_socket: Socket,
    rt: io.Runtime,
    allocator: std.mem.Allocator,

    pub fn step(ctx: *anyopaque, id: io.TaskId, result: io.Result) ?io.AsyncSubmission {
        const self: *Acceptor = @ptrCast(@alignCast(ctx));
        _ = id;

        const tardy_socket = result.accept.unwrap() catch
            return self.listen_socket.acceptSubmission();

        self.spawnConnection(tardy_socket.handle) catch {};

        return self.listen_socket.acceptSubmission();
    }

    fn spawnConnection(self: *Acceptor, fd: std.posix.socket_t) !void {
        const conn = try self.allocator.create(Connection);
        conn.* = .{ .fd = fd };
        const conn_id = try self.rt.register(@ptrCast(conn), Connection.step);
        try self.rt.submit(conn_id, conn.recvSubmission());
    }
};
