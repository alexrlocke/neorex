const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "neorex",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // for termios, ioctl, read, write, poll
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // tests reach every file through main.zig's test block
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // golden tests: renderer output through Ghostty's terminal emulator
    const golden = b.option(bool, "golden", "Run the golden tests too (downloads Ghostty)") orelse false;
    if (!golden) return;
    // asked for only here, so other builds never download it
    const dep = b.lazyDependency("ghostty", .{}) orelse return;
    const golden_mod = b.createModule(.{
        .root_source_file = b.path("src/golden.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    golden_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    const golden_tests = b.addTest(.{ .root_module = golden_mod });
    test_step.dependOn(&b.addRunArtifact(golden_tests).step);
}
