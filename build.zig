const std = @import("std");
const builtin = @import("builtin");

fn linkPython(m: *std.Build.Module) void {
    const os = m.resolved_target.?.result.os.tag;
    if (os == .macos) {
        m.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/include/python3.14" });
        m.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/lib" });
    } else {
        m.addIncludePath(.{ .cwd_relative = "sysroot/linux-aarch64/include/python3.14" });
        m.addLibraryPath(.{ .cwd_relative = "sysroot/linux-aarch64/lib" });
    }
    m.linkSystemLibrary("python3.14", .{});
    m.link_libc = true;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Library module ---
    const mod = b.addModule("snek", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    linkPython(mod);

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

    // --- Zig benchmark server (uses snek module, needs Python for compilation) ---
    const bench_zig = b.addExecutable(.{
        .name = "bench-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/controls/zig/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "snek", .module = mod },
            },
        }),
    });
    b.installArtifact(bench_zig);

    // --- Python extension shared library (_snek.so) ---
    const pyext_step = b.step("pyext", "Build _snek Python extension (.so/.dylib)");
    const pyext = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "_snek",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    linkPython(pyext.root_module);
    // Ad-hoc codesign after build (macOS requires valid signature for dlopen)
    const codesign = b.addSystemCommand(&.{ "codesign", "-fs", "-" });
    codesign.addFileArg(pyext.getEmittedBin());
    codesign.step.dependOn(&pyext.step);
    b.installArtifact(pyext);
    pyext_step.dependOn(&codesign.step);

    // --- Embedded runner (snek_runner) ---
    const runner = b.addExecutable(.{
        .name = "snek_runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/snek_runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    linkPython(runner.root_module);
    b.installArtifact(runner);

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
        // server.zig imports python/subinterp.zig; tested in python_test_sources
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

    // Python FFI modules — need CPython include/lib paths
    const python_test_sources = [_][]const u8{
        "src/python/ffi.zig",
        "src/python/gil.zig",
        "src/python/driver.zig",
        "src/python/coerce.zig",
        "src/python/context.zig",
        "src/python/inject.zig",
        "src/python/module.zig",
        // subinterp.zig uses cross-domain imports; tested via root module
        "src/server.zig",
    };

    for (python_test_sources) |source| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(source),
                .target = target,
                .optimize = optimize,
            }),
        });
        linkPython(t.root_module);
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }
}
