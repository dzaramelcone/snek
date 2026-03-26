//! Accept loop — spawns connections on new client fds.

const std = @import("std");
const IoOp = @import("aio/io_op.zig").IoOp;
const IoResult = @import("aio/io_op.zig").IoResult;
const Task = @import("task.zig").Task;
const Runtime = @import("runtime.zig").Runtime;
const conn_mod = @import("connection.zig");
const Pool = @import("pool.zig").Pool;

const log = std.log.scoped(.@"snek/acceptor");

pub const AcceptCtx = struct {
    listen_fd: std.posix.socket_t,
    rt: *Runtime,
    connections: *Pool(conn_mod.ConnCtx),
    tasks: *Pool(Task),
    allocator: std.mem.Allocator,
};

pub fn onAccept(ctx: *AcceptCtx, task: *Task, res: IoResult) ?IoOp {
    if (res >= 0) {
        const fd: std.posix.socket_t = @intCast(res);
        log.debug("accepted fd={d}", .{fd});
        spawnConnection(ctx, fd) catch |err| {
            log.debug("spawn failed: {}", .{err});
            std.posix.close(fd);
        };
    } else {
        log.debug("accept error: {d}", .{res});
    }
    // Always re-arm accept
    _ = task;
    return IoOp{ .accept = .{ .socket = ctx.listen_fd } };
}

fn spawnConnection(ctx: *AcceptCtx, fd: std.posix.socket_t) !void {
    const conn_idx = try ctx.connections.borrow();
    const conn = ctx.connections.get_ptr(conn_idx);
    try conn.ensureInit(ctx.allocator);
    conn.reset();
    conn.fd = fd;
    conn.pool_index = conn_idx;
    conn.connections = ctx.connections;
    conn.tasks = ctx.tasks;

    const task_idx = try ctx.tasks.borrow();
    const t = ctx.tasks.get_ptr(task_idx);
    t.* = Task.init(conn_mod.ConnCtx, conn, conn_mod.onRecv);
    conn.task_index = task_idx;

    conn.recv_slice = conn.zc.get_write_area(4096) catch return error.OutOfMemory;
    try ctx.rt.queue(t, IoOp{ .recv = .{ .socket = fd, .buffer = conn.recv_slice } });
}
