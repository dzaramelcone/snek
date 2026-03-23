const std = @import("std");
const zio = @import("zio");

fn handleClient(stream: zio.net.Stream) !void {
    defer stream.close();

    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(&read_buffer);

    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(&write_buffer);

    var server = std.http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.ReadFailed => |e| return reader.err orelse e,
            else => |e| return e,
        };

        const target = request.head.target;

        if (std.mem.eql(u8, target, "/")) {
            try request.respond("{\"message\":\"hello\"}", .{
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                    .{ .name = "connection", .value = "close" },
                },
            });
        } else if (std.mem.eql(u8, target, "/health")) {
            try request.respond("{\"status\":\"ok\"}", .{
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                    .{ .name = "connection", .value = "close" },
                },
            });
        } else {
            try request.respond("Not Found", .{
                .status = .not_found,
                .extra_headers = &.{
                    .{ .name = "connection", .value = "close" },
                },
            });
        }

        try stream.shutdown(.both);
        break;
    }
}

pub fn main() !void {
    const rt = try zio.Runtime.init(std.heap.smp_allocator, .{
        .executors = .exact(2),
    });
    defer rt.deinit();

    var args = std.process.args();
    _ = args.next();
    const port_str = args.next() orelse "8080";
    const port = std.fmt.parseInt(u16, port_str, 10) catch 8080;

    const addr = try zio.net.IpAddress.parseIp4("0.0.0.0", port);
    const server = try addr.listen(.{ .reuse_address = true });
    defer server.close();

    std.debug.print("zio control listening on http://0.0.0.0:{d}/\n", .{port});

    var group: zio.Group = .init;
    defer group.cancel();

    while (true) {
        const stream = try server.accept();
        errdefer stream.close();
        try group.spawn(handleClient, .{stream});
    }
}
