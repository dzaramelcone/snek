//! Accept state machine — borrows provisions from pool, spawns connections.

const std = @import("std");
const io = @import("io.zig");
const Socket = @import("socket.zig").Socket;
const Provision = @import("connection.zig").Provision;
const tardy = @import("vendor/tardy/lib.zig");
const Pool = tardy.Pool;

pub const Acceptor = struct {
    listen_socket: Socket,
    rt: io.Runtime,
    provisions: *Pool(Provision),
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
        const idx = try self.provisions.borrow();
        const prov = self.provisions.get_ptr(idx);
        try prov.ensureInit(self.allocator);
        try prov.reset();
        prov.fd = fd;
        prov.pool_index = idx;
        prov.rt = self.rt;
        prov.provisions = self.provisions;

        const task_id = try self.rt.register(@ptrCast(prov), Provision.step);
        prov.task_id = task_id;
        try self.rt.submit(task_id, (Socket{ .handle = fd, .addr = undefined }).recvSubmission(prov.recv_slice));
    }
};
