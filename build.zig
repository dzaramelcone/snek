const std = @import("std");
const builtin = @import("builtin");

fn linkPython(m: *std.Build.Module) void {
    const target = m.resolved_target.?.result;
    if (target.os.tag == .macos) {
        m.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/include/python3.14" });
        m.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/lib" });
    } else if (target.cpu.arch == .aarch64) {
        m.addIncludePath(.{ .cwd_relative = "sysroot/linux-aarch64/include/python3.14" });
        m.addLibraryPath(.{ .cwd_relative = "sysroot/linux-aarch64/lib" });
    } else {
        m.addIncludePath(.{ .cwd_relative = "sysroot/linux-x86_64/include/python3.14" });
        m.addLibraryPath(.{ .cwd_relative = "sysroot/linux-x86_64/lib" });
    }
    m.linkSystemLibrary("python3.14", .{});
    m.link_libc = true;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_cross = target.result.os.tag != builtin.os.tag or target.result.cpu.arch != builtin.cpu.arch;

    // ── Python extension (_snek.so / .dylib) — the main artifact ────
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
    const pyext_step = b.step("pyext", "Build _snek Python extension (.so/.dylib)");
    const install_pyext = b.addInstallArtifact(pyext, .{});
    if (target.result.os.tag == .macos) {
        const codesign = b.addSystemCommand(&.{ "codesign", "-fs", "-" });
        codesign.addFileArg(pyext.getEmittedBin());
        codesign.step.dependOn(&pyext.step);
        install_pyext.step.dependOn(&codesign.step);
    } else {
        install_pyext.step.dependOn(&pyext.step);
    }
    pyext_step.dependOn(&install_pyext.step);

    // ── Benchmarks ──────────────────────────────────────────────────
    if (!is_cross) {
        const zio_dep = b.dependency("zio", .{ .target = target, .optimize = optimize });
        const tardy_dep = b.dependency("tardy", .{ .target = target, .optimize = optimize });

        const bench_zio = b.addExecutable(.{
            .name = "bench-zio",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/controls/zig-zio/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zio", .module = zio_dep.module("zio") },
                },
            }),
        });
        b.installArtifact(bench_zio);

        const bench_tardy = b.addExecutable(.{
            .name = "bench-tardy",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/controls/zig-tardy/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "tardy", .module = tardy_dep.module("tardy") },
                },
            }),
        });
        b.installArtifact(bench_tardy);

        const bench_json = b.addExecutable(.{
            .name = "bench-json-escape",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/json_escape.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{ .name = "serialize", .module = b.createModule(.{
                        .root_source_file = b.path("src/json/serialize.zig"),
                        .target = target,
                        .optimize = .ReleaseFast,
                    }) },
                },
            }),
        });
        b.installArtifact(bench_json);

        const bench_json_step = b.step("bench-json", "Run JSON escape benchmark");
        const bench_json_run = b.addRunArtifact(bench_json);
        bench_json_step.dependOn(&bench_json_run.step);
        bench_json_run.step.dependOn(b.getInstallStep());
    }

    // ── Tests (native only) ─────────────────────────────────────────
    if (is_cross) return;

    const test_step = b.step("test", "Run all unit tests");

    const test_sources = [_][]const u8{
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
        "src/http/request.zig",
        "src/http/response.zig",
        "src/http/router.zig",
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
        "src/cli/main.zig",
        "src/cli/commands.zig",
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
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Python modules with C API dependencies
    const python_test_sources = [_][]const u8{
        "src/python/ffi.zig",
        "src/python/gil.zig",
        "src/python/coerce.zig",
        "src/python/context.zig",
        "src/python/inject.zig",
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
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Full lib test (driver.zig, module.zig cross-import via lib root)
    {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/lib.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        linkPython(t.root_module);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
