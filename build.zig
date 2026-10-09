const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const db_mod = b.createModule(.{
        .root_source_file = b.path("src/db/root.zig"),
        .target = target,
        .optimize = optimize,
        // C hosts use libc startup; pthreads do not depend on Zig TLS startup.
        .link_libc = true,
    });
    const db_abi_options = b.addOptions();
    db_abi_options.addOption(bool, "enable_abi_exports", true);
    db_mod.addOptions("db_build_options", db_abi_options);

    const db_internal_mod = b.createModule(.{
        .root_source_file = b.path("src/db/internal.zig"),
        .target = target,
        .optimize = optimize,
    });
    const db_internal_options = b.addOptions();
    db_internal_options.addOption(bool, "enable_abi_exports", false);
    db_internal_mod.addOptions("db_build_options", db_internal_options);

    const tests = b.addTest(.{
        .root_module = db_mod,
    });

    const vfs_mod = b.createModule(.{
        .root_source_file = b.path("src/vfs/root.zig"),
        .target = target,
        .optimize = optimize,
        // C hosts use libc startup; pthreads do not depend on Zig TLS startup.
        .link_libc = true,
        .imports = &.{.{ .name = "db_internal", .module = db_internal_mod }},
    });
    vfs_mod.addIncludePath(b.path("include"));

    const vfs_tests = b.addTest(.{
        .root_module = vfs_mod,
    });

    const static_lib = b.addLibrary(.{
        .name = "db",
        .root_module = db_mod,
        .linkage = .static,
    });
    b.installArtifact(static_lib);

    const shared_mod = b.createModule(.{
        .root_source_file = b.path("src/db/root.zig"),
        .target = target,
        .optimize = optimize,
        // C hosts use libc startup; pthreads do not depend on Zig TLS startup.
        .link_libc = true,
    });
    const db_shared_options = b.addOptions();
    db_shared_options.addOption(bool, "enable_abi_exports", true);
    shared_mod.addOptions("db_build_options", db_shared_options);
    const shared_lib = b.addLibrary(.{
        .name = "db_shared",
        .root_module = shared_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(shared_lib);
    b.installFile("include/db.h", "include/db.h");

    const vfs_static_lib = b.addLibrary(.{
        .name = "vfs",
        .root_module = vfs_mod,
        .linkage = .static,
    });
    b.installArtifact(vfs_static_lib);

    const vfs_shared_mod = b.createModule(.{
        .root_source_file = b.path("src/vfs/root.zig"),
        .target = target,
        .optimize = optimize,
        // C hosts use libc startup; pthreads do not depend on Zig TLS startup.
        .link_libc = true,
        .imports = &.{.{ .name = "db_internal", .module = db_internal_mod }},
    });
    vfs_shared_mod.addIncludePath(b.path("include"));
    const vfs_shared_lib = b.addLibrary(.{
        .name = "vfs_shared",
        .root_module = vfs_shared_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(vfs_shared_lib);
    b.installFile("include/vfs.h", "include/vfs.h");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("tools/db.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "db", .module = db_mod }},
    });
    const exe = b.addExecutable(.{
        .name = "db",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const vfs_exe_mod = b.createModule(.{
        .root_source_file = b.path("tools/vfs.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "vfs", .module = vfs_mod }},
    });
    const vfs_exe = b.addExecutable(.{
        .name = "vfs",
        .root_module = vfs_exe_mod,
    });
    b.installArtifact(vfs_exe);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("tests/vfs_concurrent_read_bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vfs", .module = vfs_mod },
            .{ .name = "db_internal", .module = db_internal_mod },
        },
    });
    const bench_exe = b.addExecutable(.{
        .name = "vfs_concurrent_read_bench",
        .root_module = bench_mod,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench-read", "Benchmark sequential vs concurrent VFS reads (pass max thread count as -- N)");
    bench_step.dependOn(&run_bench.step);

    const vfs_pack_roundtrip = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/vfs_pack_roundtrip.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vfs", .module = vfs_mod }},
        }),
    });

    const abi_step = b.step("test-abi", "Run C11 and C++17 consumers of DB/VFS static and shared libraries");
    const abi_compile_step = b.step("check-abi", "Compile and link all ABI consumers without executing target code");
    for ([_]bool{ false, true }) |cpp| {
        for ([_]bool{ false, true }) |shared| {
            const label = b.fmt("{s}_{s}", .{ if (cpp) "cpp" else "c", if (shared) "shared" else "static" });
            const db_smoke = addAbiConsumer(b, target, optimize, if (shared) shared_lib else static_lib, "db", "tests/cabi_smoke.c", cpp, shared, label);
            abi_compile_step.dependOn(&db_smoke.step);
            const run_db = b.addRunArtifact(db_smoke);
            run_db.addArg(b.fmt(".zig-cache/db_cabi_smoke_{s}", .{label}));
            run_db.has_side_effects = true;
            abi_step.dependOn(&run_db.step);
            const run_vfs = addVfsCabiSmoke(b, target, optimize, if (shared) vfs_shared_lib else vfs_static_lib, vfs_exe, cpp, shared, label, abi_compile_step);
            abi_step.dependOn(&run_vfs.step);
        }
    }

    const run_tests = b.addRunArtifact(tests);
    const run_vfs_tests = b.addRunArtifact(vfs_tests);
    const run_vfs_pack_roundtrip = b.addRunArtifact(vfs_pack_roundtrip);
    // These tests mutate fixed fixtures and include concurrency/fault checks.
    // Repeated reliability invocations must execute them, not reuse a pass.
    run_tests.has_side_effects = true;
    run_vfs_tests.has_side_effects = true;
    run_vfs_pack_roundtrip.has_side_effects = true;
    const process_recovery = b.addExecutable(.{
        .name = "vfs_patch_process",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/vfs_patch_process.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vfs", .module = vfs_mod }},
        }),
    });
    const run_process_recovery = b.addRunArtifact(process_recovery);
    run_process_recovery.has_side_effects = true;
    const test_heavy = b.step("test-heavy", "Run isolated real process-death recovery tests");
    test_heavy.dependOn(&run_process_recovery.step);

    const test_step = b.step("test", "Run DB unit and integration tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_vfs_tests.step);
    test_step.dependOn(&run_vfs_pack_roundtrip.step);
    test_step.dependOn(abi_step);
    test_step.dependOn(&exe.step);
    test_step.dependOn(&vfs_exe.step);
    test_step.dependOn(&static_lib.step);
    test_step.dependOn(&shared_lib.step);
    test_step.dependOn(&vfs_static_lib.step);
    test_step.dependOn(&vfs_shared_lib.step);
}

// Both C startup modes must exercise background thread creation. Merely
// running Zig tests cannot detect a library compiled for the wrong TLS ABI.
fn addVfsCabiSmoke(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, library: *std.Build.Step.Compile, vfs_exe: *std.Build.Step.Compile, cpp: bool, shared: bool, label: []const u8, compile_step: *std.Build.Step) *std.Build.Step.Run {
    const vfs_cabi_smoke = addAbiConsumer(b, target, optimize, library, "vfs", "tests/vfs_cabi_smoke.c", cpp, shared, label);
    compile_step.dependOn(&vfs_cabi_smoke.step);

    const smoke_assets = b.addWriteFiles();
    const smoke_payload = smoke_assets.add("a.bin", "hello-vfs-cabi");
    const smoke_payload_v2 = smoke_assets.add("a_v2.bin", "hello-vfs-cabi-v2-patched");
    const smoke_pack_dir = b.fmt(".zig-cache/vfs_cabi_smoke_{s}_pack", .{label});
    const smoke_pack_v2_dir = b.fmt(".zig-cache/vfs_cabi_smoke_{s}_pack_v2", .{label});
    const smoke_diff_dir = b.fmt(".zig-cache/vfs_cabi_smoke_{s}_diff", .{label});

    const prepare_pack = b.addRunArtifact(vfs_exe);
    prepare_pack.addArg("put-file");
    prepare_pack.addArg(smoke_pack_dir);
    prepare_pack.addArg("/textures/a.bin");
    prepare_pack.addArg("1001");
    prepare_pack.addFileArg(smoke_payload);
    prepare_pack.addArg("1");
    // The smoke patches the v1 pack in place; always rebuild it first.
    prepare_pack.has_side_effects = true;

    const prepare_pack_v2 = b.addRunArtifact(vfs_exe);
    prepare_pack_v2.addArg("put-file");
    prepare_pack_v2.addArg(smoke_pack_v2_dir);
    prepare_pack_v2.addArg("/textures/a.bin");
    prepare_pack_v2.addArg("1001");
    prepare_pack_v2.addFileArg(smoke_payload_v2);
    prepare_pack_v2.addArg("2");
    prepare_pack_v2.has_side_effects = true;

    const prepare_diff = b.addRunArtifact(vfs_exe);
    prepare_diff.addArg("diff-pack");
    prepare_diff.addArg(smoke_pack_dir);
    prepare_diff.addArg(smoke_pack_v2_dir);
    prepare_diff.addArg(smoke_diff_dir);
    prepare_diff.has_side_effects = true;
    prepare_diff.step.dependOn(&prepare_pack.step);
    prepare_diff.step.dependOn(&prepare_pack_v2.step);

    const run_vfs_cabi_smoke = b.addRunArtifact(vfs_cabi_smoke);
    run_vfs_cabi_smoke.addArg(smoke_pack_dir);
    run_vfs_cabi_smoke.addArg(smoke_diff_dir);
    run_vfs_cabi_smoke.has_side_effects = true;
    run_vfs_cabi_smoke.step.dependOn(&prepare_diff.step);

    return run_vfs_cabi_smoke;
}

fn addAbiConsumer(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, library: *std.Build.Step.Compile, api: []const u8, source: []const u8, cpp: bool, shared: bool, label: []const u8) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = b.fmt("{s}_abi_{s}", .{ api, label }),
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path(source),
        .language = if (cpp) .cpp else .c,
        .flags = if (cpp) &.{ "-std=c++17", "-Wall", "-Wextra", "-Werror", "-Wno-missing-field-initializers" } else &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    if (shared) exe.root_module.addCMacro(if (std.mem.eql(u8, api, "db")) "DB_SHARED" else "VFS_SHARED", "1");
    exe.root_module.addIncludePath(b.path("include"));
    exe.root_module.linkLibrary(library);
    return exe;
}
