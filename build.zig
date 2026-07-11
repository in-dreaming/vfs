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

    const run_tests = b.addRunArtifact(tests);
    const run_vfs_tests = b.addRunArtifact(vfs_tests);
    const test_step = b.step("test", "Run DB unit and integration tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_vfs_tests.step);
    test_step.dependOn(&exe.step);
    test_step.dependOn(&vfs_exe.step);
    test_step.dependOn(&static_lib.step);
    test_step.dependOn(&shared_lib.step);
    test_step.dependOn(&vfs_static_lib.step);
    test_step.dependOn(&vfs_shared_lib.step);
}
