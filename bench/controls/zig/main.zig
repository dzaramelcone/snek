const std = @import("std");
const snek = @import("snek");

const server_mod = snek.server;
const http1 = snek.net.http1;
const response_mod = snek.http.response;

fn hello(_: *const http1.Parser) response_mod.Response {
    return response_mod.Response.json("{\"message\":\"hello\"}");
}

fn health(_: *const http1.Parser) response_mod.Response {
    return response_mod.Response.json("{\"status\":\"ok\"}");
}

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    const port_str = args.next() orelse "8080";
    const port = std.fmt.parseInt(u16, port_str, 10) catch 8080;

    var srv = try server_mod.Server.init(std.heap.page_allocator, .{});
    defer srv.deinit();

    try srv.addRoute(.GET, "/", &hello);
    try srv.addRoute(.GET, "/health", &health);

    try srv.listen("0.0.0.0", port);
    std.debug.print("zig control listening on http://0.0.0.0:{d}/\n", .{port});
    try srv.run();
}
