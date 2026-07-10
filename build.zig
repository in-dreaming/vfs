const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const db_mod = b.createModule(.{
        .root_source_file = b.path("src/db/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = db_mod,
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
    const shared_lib = b.addLibrary(.{
        .name = "db_shared",
        .root_module = shared_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(shared_lib);
    b.installFile("include/db.h", "include/db.h");

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

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run DB unit and integration tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&exe.step);
    test_step.dependOn(&static_lib.step);
    test_step.dependOn(&shared_lib.step);
}
