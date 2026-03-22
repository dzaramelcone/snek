//! CLI commands: run, db, check, routes, version.
//!
//! Each command parses snek.toml, validates config, then performs its action.
//! All commands support --help for per-command usage.

const std = @import("std");
const cli_main = @import("main.zig");

/// Start the server: parse snek.toml, init scheduler, bind, serve.
pub fn runServer(args: cli_main.CliArgs) !void {
    _ = .{args};
}

/// Create database from schema.sql.
pub fn dbCreate(args: cli_main.CliArgs) !void {
    _ = .{args};
}

/// Run pending migrations in order.
pub fn dbMigrate(args: cli_main.CliArgs) !void {
    _ = .{args};
}

/// Undo the last applied migration.
pub fn dbRollback(args: cli_main.CliArgs) !void {
    _ = .{args};
}

/// Show applied and pending migrations.
pub fn dbStatus(args: cli_main.CliArgs) !void {
    _ = .{args};
}

/// Compare schema.sql to the live database, report differences.
pub fn dbDiff(args: cli_main.CliArgs) !void {
    _ = .{args};
}

/// Drop and recreate the database from schema.sql.
pub fn dbReset(args: cli_main.CliArgs) !void {
    _ = .{args};
}

/// Print all registered routes with methods, params, and handler names.
pub fn listRoutes(args: cli_main.CliArgs) !void {
    _ = .{args};
}

/// Validate snek.toml, schema.sql, and compiled queries without starting the server.
pub fn checkConfig(args: cli_main.CliArgs) !void {
    _ = .{args};
}

/// Print snek version and build info.
pub fn printVersion() void {}

test "command run server" {}

test "command db create" {}

test "command db migrate" {}

test "command db rollback" {}

test "command db status" {}

test "command db diff" {}

test "command db reset" {}

test "command list routes" {}

test "command check config" {}

test "command print version" {}
