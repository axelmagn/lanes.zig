const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("lanes", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod_tests = b.addTest(.{ .root_module = mod });
    const mod_tests_run = b.addRunArtifact(mod_tests);
    const mod_tests_step = b.step("test", "run unit tests");
    mod_tests_step.dependOn(&mod_tests_run.step);
}
