//! Event loop — submit IoOps, wait for completions, call task.step().
//!
//! No task registry. Tasks are long-lived structs (Connection, accept loop)
//! whose pointers round-trip through the kernel via user_data/udata.

const std = @import("std");
const aio = @import("aio/lib.zig");
const Task = @import("task.zig").Task;

const log = std.log.scoped(.@"snek/runtime");

pub const Runtime = struct {
    backend: aio.Backend,
    running: bool = true,

    pub fn init(allocator: std.mem.Allocator, entries: u16) !Runtime {
        return .{
            .backend = try aio.Backend.init(allocator, entries),
        };
    }

    pub fn deinit(self: *Runtime, allocator: std.mem.Allocator) void {
        self.backend.deinit(allocator);
    }

    pub fn queue(self: *Runtime, task: *Task, op: aio.IoOp) !void {
        try self.backend.queue(task, op);
    }

    pub fn run(self: *Runtime) !void {
        while (self.running) {
            // Block until at least 1 event
            _ = try self.processCompletions(1);

            // Drain: keep processing ready events without blocking
            while (true) {
                const had_work = try self.processCompletions(0);
                if (!had_work) break;
            }
        }
    }

    /// Submit pending ops, wait for completions, call step on each.
    /// Returns true if any completions were processed.
    fn processCompletions(self: *Runtime, wait_nr: u32) !bool {
        const completions = try self.backend.submitAndWait(wait_nr);

        for (completions.tasks, completions.results) |task, result| {
            if (task.step(task, result)) |next_op| {
                try self.backend.queue(task, next_op);
            }
        }

        return completions.tasks.len > 0;
    }
};
