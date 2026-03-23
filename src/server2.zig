//! snek HTTP server — stackless, built on io.Runtime.

const std = @import("std");
const io = @import("io.zig");
const Socket = @import("socket.zig").Socket;
const Stackless = @import("runtime.zig").Stackless;
const Acceptor = @import("acceptor.zig").Acceptor;

const aio_lib = @import("vendor/tardy/aio/lib.zig");
const completion_mod = @import("vendor/tardy/aio/completion.zig");

pub fn run(allocator: std.mem.Allocator, host: []const u8, port: u16) !void {
    const listen_socket = try Socket.initTcp(host, port);
    try listen_socket.bind();
    try listen_socket.listen(128);

    const num_threads = @max(1, std.Thread.getCpuCount() catch 1);

    var threads: std.ArrayList(std.Thread) = .{};
    defer {
        for (threads.items) |t| t.join();
        threads.deinit(allocator);
    }

    for (1..num_threads) |_| {
        const t = try std.Thread.spawn(.{}, threadMain, .{ allocator, listen_socket });
        try threads.append(allocator, t);
    }

    try threadMain(allocator, listen_socket);
}

fn threadMain(allocator: std.mem.Allocator, listen_socket: Socket) !void {
    const AioType = aio_lib.async_to_type(aio_lib.auto_async_match());
    var aio_inner = try allocator.create(AioType);
    aio_inner.* = try AioType.init(allocator, .{
        .parent_async = null,
        .pooling = .grow,
        .size_tasks_initial = 1024,
        .size_aio_reap_max = 1024,
    });
    var aio = aio_inner.to_async();
    const completions = try allocator.alloc(completion_mod.Completion, 1024);
    aio.attach(completions);

    var stackless = try Stackless.init(allocator, aio, 65536);
    defer stackless.deinit();
    const rt = stackless.runtime();

    var acceptor = Acceptor{
        .listen_socket = listen_socket,
        .rt = rt,
        .allocator = allocator,
    };
    const accept_id = try rt.register(@ptrCast(&acceptor), Acceptor.step);
    try rt.submit(accept_id, listen_socket.acceptSubmission());

    try rt.run();
}
