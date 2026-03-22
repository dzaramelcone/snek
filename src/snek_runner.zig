//! snek runner — embeds CPython, registers the _snek module, runs a Python app.
//!
//! Usage: zig build-exe src/snek_runner.zig ... && ./snek_runner example/hello/app.py

const std = @import("std");
const ffi = @import("python/ffi.zig");
const module = @import("python/module.zig");

pub fn main() !void {
    var args = std.process.args();
    _ = args.next(); // skip argv[0]
    const script = args.next() orelse {
        std.debug.print("Usage: snek <app.py>\n", .{});
        return;
    };

    // Register the _snek built-in module BEFORE Py_Initialize
    module.registerBuiltin();

    // Start Python
    ffi.init();
    defer ffi.deinit();

    // Build the exec command
    var cmd_buf: [4096]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "exec(open('{s}').read())", .{script});
    cmd_buf[cmd.len] = 0;
    try ffi.runString(cmd_buf[0..cmd.len :0]);
}
