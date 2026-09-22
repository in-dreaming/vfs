const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const db_mod = b.createModule(.{
        .root_source_file = b.path("src/db/root.zig"),
        .target = target,
        .optimize = optimize,
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

    const vfs_cabi_smoke = b.addExecutable(.{
        .name = "vfs_cabi_smoke",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    vfs_cabi_smoke.root_module.addCSourceFile(.{
        .file = b.path("tests/vfs_cabi_smoke.c"),
        .flags = &.{},
    });
    vfs_cabi_smoke.root_module.addIncludePath(b.path("include"));
    vfs_cabi_smoke.root_module.linkLibrary(vfs_static_lib);

    const smoke_assets = b.addWriteFiles();
    const smoke_payload = smoke_assets.add("a.bin", "hello-vfs-cabi");
    const smoke_payload_v2 = smoke_assets.add("a_v2.bin", "hello-vfs-cabi-v2-patched");
    const smoke_pack_dir = ".zig-cache/vfs_cabi_smoke_pack";
    const smoke_pack_v2_dir = ".zig-cache/vfs_cabi_smoke_pack_v2";
    const smoke_diff_dir = ".zig-cache/vfs_cabi_smoke_diff";

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

    const run_tests = b.addRunArtifact(tests);
    const run_vfs_tests = b.addRunArtifact(vfs_tests);
    const run_vfs_pack_roundtrip = b.addRunArtifact(vfs_pack_roundtrip);
    const test_step = b.step("test", "Run DB unit and integration tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_vfs_tests.step);
    test_step.dependOn(&run_vfs_pack_roundtrip.step);
    test_step.dependOn(&run_vfs_cabi_smoke.step);
    test_step.dependOn(&exe.step);
    test_step.dependOn(&vfs_exe.step);
    test_step.dependOn(&static_lib.step);
    test_step.dependOn(&shared_lib.step);
    test_step.dependOn(&vfs_static_lib.step);
    test_step.dependOn(&vfs_shared_lib.step);
}
