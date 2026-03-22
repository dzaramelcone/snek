const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Library module ---
    const mod = b.addModule("snek", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // --- Executable ---
    const exe = b.addExecutable(.{
        .name = "snek",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "snek", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the snek CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // --- Tests ---
    const test_step = b.step("test", "Run all unit tests");

    // Library module tests
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    test_step.dependOn(&run_mod_tests.step);

    // Executable module tests
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_exe_tests.step);

    // Individual module tests
    const test_sources = [_][]const u8{
        "src/core/coroutine.zig",
        "src/core/scheduler.zig",
        "src/core/io.zig",
        "src/core/worker.zig",
        "src/core/deque.zig",
        "src/core/io_uring.zig",
        "src/core/kqueue.zig",
        "src/core/timer.zig",
        "src/core/buffer.zig",
        "src/core/signal.zig",
        "src/core/fake_io.zig",
        "src/core/static_alloc.zig",
        "src/core/pool.zig",
        "src/core/arena.zig",
        "src/core/coverage.zig",
        "src/core/assert.zig",
        "src/net/tcp.zig",
        "src/net/tls.zig",
        "src/net/http1.zig",
        "src/net/http2.zig",
        "src/net/websocket.zig",
        "src/python/ffi.zig",
        "src/python/gil.zig",
        "src/python/driver.zig",
        "src/python/coerce.zig",
        "src/python/context.zig",
        "src/python/inject.zig",
        "src/python/module.zig",
        "src/db/wire.zig",
        "src/db/pool.zig",
        "src/db/query.zig",
        "src/db/schema.zig",
        "src/db/types.zig",
        "src/db/auth.zig",
        "src/db/pipeline.zig",
        "src/db/notify.zig",
        "src/redis/protocol.zig",
        "src/redis/connection.zig",
        "src/redis/pool.zig",
        "src/redis/commands.zig",
        "src/redis/pubsub.zig",
        "src/redis/lua.zig",
        "src/http/request.zig",
        "src/http/response.zig",
        "src/http/router.zig",
        "src/server.zig",
        "src/http/middleware.zig",
        "src/http/cookies.zig",
        "src/http/compress.zig",
        "src/http/validate.zig",
        "src/json/parse.zig",
        "src/json/serialize.zig",
        "src/security/cors.zig",
        "src/security/headers.zig",
        "src/security/jwt.zig",
        "src/observe/log.zig",
        "src/observe/metrics.zig",
        "src/observe/health.zig",
        "src/observe/trace.zig",
        "src/config/toml.zig",
        "src/config/env.zig",
        "src/serve/static.zig",
        // src/serve/client.zig uses cross-domain imports; tested via root module
        "src/cli/main.zig",
        "src/cli/commands.zig",
        // src/testing/client.zig and fake_client.zig use cross-domain imports; tested via root module
        "src/testing/conformance.zig",
        "src/testing/simulation.zig",
    };

    for (test_sources) |source| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(source),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }
}
