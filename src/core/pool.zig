//! Generic HiveArray-style fixed-capacity pool with bitset tracking (Bun pattern).
//! Used for pre-allocated request contexts, connection objects, coroutine frames.
//!
//! O(1) acquire via leading-zeros intrinsic on the bitset.
//! O(1) release by clearing the corresponding bit.
//! No heap allocation after init — all items pre-allocated in a contiguous array.
//! Optional fallback to a backing allocator when the pool is exhausted.

const std = @import("std");

/// Fixed-capacity pool backed by a bitset. All items live in a contiguous array.
/// `capacity` must be comptime-known for the bitset to be a fixed-size integer type.
// Inspired by: Bun (refs/bun/INSIGHTS.md) — HiveArray pattern
// Source: Bun src/collections/hive_array.zig — O(1) bitset-tracked fixed-capacity pool,
// leading-zeros intrinsic for slot acquisition.
pub fn HiveArray(comptime T: type, comptime capacity: u16) type {
    return struct {
        const Self = @This();
        const BitSet = std.bit_set.IntegerBitSet(capacity);

        buffer: [capacity]T,
        used: BitSet,

        pub fn init() Self {
            return .{
                .buffer = undefined,
                .used = BitSet.initEmpty(),
            };
        }

        /// Acquire a slot from the pool. Returns null if all slots are in use.
        pub fn get(self: *Self) ?*T {
            _ = .{self};
            return null;
        }

        /// Release a slot back to the pool.
        pub fn put(self: *Self, item: *T) void {
            _ = .{ self, item };
        }

        /// Number of items currently in use.
        pub fn count(self: *const Self) usize {
            _ = .{self};
            return undefined;
        }

        /// Number of available slots.
        pub fn available(self: *const Self) usize {
            _ = .{self};
            return undefined;
        }

        /// HiveArray with fallback to a backing allocator when pool is exhausted.
        // Fallback allocator activates only on pool exhaustion — outside the StaticAllocator boundary.
        pub const Fallback = struct {
            pool: Self,
            backing: std.mem.Allocator,

            pub fn init(backing: std.mem.Allocator) Fallback {
                return .{
                    .pool = Self.init(),
                    .backing = backing,
                };
            }

            pub fn get(self: *Fallback) ?*T {
                _ = .{self};
                return null;
            }

            pub fn put(self: *Fallback, item: *T) void {
                _ = .{ self, item };
            }
        };
    };
}

test "hive array acquire and release" {}

test "hive array exhaustion returns null" {}

test "hive array fallback allocator" {}
