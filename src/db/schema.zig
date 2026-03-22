//! Schema SQL parser, query validation, and migrations.
//!
//! Sources:
//!   - Zero-downtime migrations: pgroll pattern — expand/contract with dual-write views.
//!     See src/db/REFERENCES_migrations.md.

pub const Column = struct {
    name: []const u8,
    col_type: []const u8,
    nullable: bool,
    primary_key: bool,
};

pub const Table = struct {
    name: []const u8,
    columns: []Column,
};

pub const Schema = struct {
    tables: []Table,
};

/// Migration with up/down SQL. Inspired by pgroll's expand/contract approach
/// for zero-downtime schema changes. See src/db/REFERENCES_migrations.md.
pub const Migration = struct {
    version: u32,
    name: []const u8,
    up_sql: []const u8,
    down_sql: []const u8,
};

pub fn parseSchema(sql: []const u8) !Schema {
    _ = .{sql};
    return undefined;
}

pub fn validateQuery(schema: Schema, sql: []const u8) !bool {
    _ = .{ schema, sql };
    return undefined;
}

pub fn runMigration(fd: i32, migration: Migration) !void {
    _ = .{ fd, migration };
}

pub fn rollback(fd: i32, migration: Migration) !void {
    _ = .{ fd, migration };
}

pub fn diff(current: Schema, target: Schema) ![]const u8 {
    _ = .{ current, target };
    return undefined;
}

test "parse schema sql" {}

test "validate query against schema" {}

test "run migration" {}

test "rollback migration" {}

test "diff schemas" {}
