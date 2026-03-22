//! CLI entry point: argument parsing and command dispatch.
//!
//! Commands: run, db {create,migrate,rollback,status,diff,reset}, routes, check, version.

const std = @import("std");
const commands = @import("commands.zig");

pub const Command = enum {
    run,
    db_create,
    db_migrate,
    db_rollback,
    db_status,
    db_diff,
    db_reset,
    routes,
    check,
    version,
    help,
};

pub const CliArgs = struct {
    command: Command,
    /// Positional args after the command.
    positional: []const []const u8,
    /// --host override.
    host: ?[]const u8,
    /// --port override.
    port: ?u16,
    /// --workers override.
    workers: ?u16,
    /// --reload flag (dev mode).
    reload: bool,
    /// --config path override (default: snek.toml).
    config_path: []const u8,
};

/// Parse CLI arguments into a CliArgs struct.
pub fn parseArgs(args: []const []const u8) !CliArgs {
    _ = .{args};
    return undefined;
}

/// Dispatch parsed command to the appropriate handler.
pub fn dispatch(cli: CliArgs) !void {
    _ = .{cli};
}

/// Print usage/help text.
pub fn printHelp() void {}

pub fn main() !void {
    const args = std.process.args();
    _ = .{args};
}

test "cli parse run command" {}

test "cli parse db subcommand" {}

test "cli parse args with overrides" {}

test "cli dispatch" {}

test "cli help output" {}

test "cli unknown command" {}
