//! Binary entry point for the snek CLI.

const cli_main = @import("cli/main.zig");

pub fn main() !void {
    try cli_main.main();
}
