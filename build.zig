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

    const examples = .{
        .{ .name = "sum", .step = "run-sum" },
        .{ .name = "radix_sort", .step = "run-radix-sort" },
    };
    const examples_step = b.step("examples", "build all examples");
    inline for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example.name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "lanes", .module = mod }},
            }),
        });
        examples_step.dependOn(&b.addInstallArtifact(exe, .{}).step);

        const run = b.addRunArtifact(exe);
        const run_step = b.step(example.step, "run " ++ example.name ++ " example");
        run_step.dependOn(&run.step);
    }
}
