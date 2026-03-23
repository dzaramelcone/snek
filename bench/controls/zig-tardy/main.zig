const std = @import("std");
const tardy = @import("tardy");

const Runtime = tardy.Runtime;
const Socket = tardy.Socket;

fn handleClient(rt: *Runtime, client: Socket) !void {
    defer client.close_blocking();

    var read_buf: [4096]u8 = undefined;
    const n = client.recv(rt, &read_buf) catch return;
    if (n == 0) return;

    const request = read_buf[0..n];
    const first_line_end = std.mem.indexOf(u8, request, "\r\n") orelse return;
    const first_line = request[0..first_line_end];

    const path_start = std.mem.indexOf(u8, first_line, " ") orelse return;
    const rest = first_line[path_start + 1 ..];
    const path_end = std.mem.indexOf(u8, rest, " ") orelse return;
    const path = rest[0..path_end];

    const body: []const u8 = if (std.mem.eql(u8, path, "/"))
        "{\"message\":\"hello\"}"
    else if (std.mem.eql(u8, path, "/health"))
        "{\"status\":\"ok\"}"
    else
        "Not Found";

    const status: []const u8 = if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/health"))
        "200 OK"
    else
        "404 Not Found";

    var resp_buf: [512]u8 = undefined;
    const resp = std.fmt.bufPrint(&resp_buf, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ status, body.len, body }) catch return;

    _ = client.send(rt, resp) catch return;
}

fn acceptLoop(rt: *Runtime, listen_socket: Socket) !void {
    while (true) {
        const client = listen_socket.accept(rt) catch continue;
        rt.spawn(.{ rt, client }, handleClient, 1024 * 128) catch continue;
    }
}

// entry_func runs on the regular stack, NOT as a coroutine.
// It must spawn the accept loop as a coroutine, then return.
fn setup(rt: *Runtime, listen_socket: Socket) !void {
    rt.spawn(.{ rt, listen_socket }, acceptLoop, 1024 * 128) catch |e| {
        std.debug.print("spawn failed: {}\n", .{e});
        return e;
    };
}

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    const port_str = args.next() orelse "8080";
    const port = std.fmt.parseInt(u16, port_str, 10) catch 8080;

    const addr = std.net.Address.parseIp4("0.0.0.0", port) catch unreachable;
    const listen_socket = try Socket.init_with_address(.tcp, addr);
    try listen_socket.bind();
    try listen_socket.listen(128);

    std.debug.print("tardy control listening on http://0.0.0.0:{d}/\n", .{port});

    const TardyImpl = tardy.Tardy(tardy.auto_async_match());
    var t = try TardyImpl.init(std.heap.smp_allocator, .{
        .threading = .{ .multi = 2 },
    });
    defer t.deinit();

    try t.entry(listen_socket, setup);
}
