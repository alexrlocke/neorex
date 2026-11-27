const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info from the binary");

    // modules, leaves first; each lists what it may import
    const rex_mod = b.createModule(.{
        .root_source_file = b.path("src/rex/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const term_mod = b.createModule(.{
        .root_source_file = b.path("src/term/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const msgpack_mod = b.createModule(.{
        .root_source_file = b.path("src/msgpack/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const screen_mod = b.createModule(.{
        .root_source_file = b.path("src/screen/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    screen_mod.addImport("msgpack", msgpack_mod);

    const nvim_mod = b.createModule(.{
        .root_source_file = b.path("src/nvim/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    nvim_mod.addImport("msgpack", msgpack_mod);
    nvim_mod.addImport("term", term_mod);

    const exe = b.addExecutable(.{
        .name = "neorex",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            // for termios, ioctl, read, write, poll
            .link_libc = true,
        }),
    });

    exe.root_module.addImport("rex", rex_mod);
    exe.root_module.addImport("term", term_mod);
    exe.root_module.addImport("msgpack", msgpack_mod);
    exe.root_module.addImport("screen", screen_mod);
    exe.root_module.addImport("nvim", nvim_mod);

    b.installArtifact(exe);
    // the colorscheme and lualine theme; neorex finds them from its own path
    // (src/nvim/runtime.zig), so every install keeps this layout
    b.installDirectory(.{
        .source_dir = b.path("runtime"),
        .install_dir = .prefix,
        .install_subdir = "share/neorex/runtime",
    });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // `test:unit` (the app and each module), `test:integration` (against a
    // real Neovim), `test:fmt`, and `test` for all three. `-Dtest-filter`
    // picks tests by name:
    //   zig build test:unit -Dtest-filter="parse response"
    // and then `test` runs only the unit tests.
    const test_filters = b.option([]const []const u8, "test-filter", "Run only the tests whose names contain this") orelse &.{};
    // tests that need nvim skip without it, or fail with -Dnvim-required (CI);
    // src/testing/nvim.zig reads it
    const test_options = b.addOptions();
    test_options.addOption(bool, "nvim_required", b.option(bool, "nvim-required", "Fail, not skip, the tests that need nvim when it isn't installed") orelse false);
    const steps = .{
        .@"test" = b.step("test", "Run all tests"),
        .test_unit = b.step("test:unit", "Run unit tests"),
        .test_unit_build = b.step("test:unit:build", "Build unit tests"),
        .test_integration = b.step("test:integration", "Run integration tests, against a real Neovim"),
        .test_integration_build = b.step("test:integration:build", "Build integration tests"),
        .test_fmt = b.step("test:fmt", "Check formatting"),
    };

    // unit tests: the app's files through main.zig's test block, then each
    // module's own; `test:<name>` runs one of them
    for ([_]struct { []const u8, *std.Build.Module }{
        .{ "app", exe.root_module },
        .{ "rex", rex_mod },
        .{ "term", term_mod },
        .{ "msgpack", msgpack_mod },
        .{ "screen", screen_mod },
        .{ "nvim", nvim_mod },
    }) |unit| {
        const tests = b.addTest(.{
            .name = b.fmt("test-{s}", .{unit[0]}),
            .root_module = unit[1],
            .filters = test_filters,
        });
        steps.test_unit_build.dependOn(&b.addInstallArtifact(tests, .{}).step);
        const run = b.addRunArtifact(tests);
        steps.test_unit.dependOn(&run.step);
        b.step(b.fmt("test:{s}", .{unit[0]}), b.fmt("Run {s}'s unit tests", .{unit[0]})).dependOn(&run.step);
    }

    // integration tests: neorex's pieces against a real Neovim; each skips
    // when nvim isn't installed
    const integration_mod = b.createModule(.{
        .root_source_file = b.path("src/integration_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    integration_mod.addImport("msgpack", msgpack_mod);
    integration_mod.addImport("screen", screen_mod);
    integration_mod.addImport("nvim", nvim_mod);
    integration_mod.addOptions("test_options", test_options);
    const integration_tests = b.addTest(.{
        .name = "test-integration",
        .root_module = integration_mod,
        .filters = test_filters,
    });
    steps.test_integration_build.dependOn(&b.addInstallArtifact(integration_tests, .{}).step);
    const run_integration = b.addRunArtifact(integration_tests);
    // they depend on the installed Neovim and on runtime/ and test/lua, none
    // of which the build sees: never cached
    run_integration.has_side_effects = true;
    // the Lua specs (test/lua) run from the repository's root
    run_integration.setCwd(b.path("."));
    steps.test_integration.dependOn(&run_integration.step);

    steps.test_fmt.dependOn(&b.addFmt(.{ .paths = &.{ b.path("src"), b.path("build.zig"), b.path("build.zig.zon") }, .check = true }).step);

    steps.@"test".dependOn(steps.test_unit);
    if (test_filters.len == 0) {
        steps.@"test".dependOn(steps.test_integration);
        steps.@"test".dependOn(steps.test_fmt);
    }

    // golden tests: renderer output through Ghostty's terminal emulator
    const golden = b.option(bool, "golden", "Run the golden tests too (downloads Ghostty)") orelse false;
    if (!golden) return;
    // asked for only here, so other builds never download it
    const dep = b.lazyDependency("ghostty", .{}) orelse return;
    const golden_mod = b.createModule(.{
        .root_source_file = b.path("src/golden_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    golden_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    golden_mod.addImport("msgpack", msgpack_mod);
    golden_mod.addImport("screen", screen_mod);
    golden_mod.addImport("nvim", nvim_mod);
    golden_mod.addOptions("test_options", test_options);
    const golden_tests = b.addTest(.{
        .name = "test-golden",
        .root_module = golden_mod,
        .filters = test_filters,
    });
    const run_golden = b.addRunArtifact(golden_tests);
    b.step("test:golden", "Run golden tests (with -Dgolden)").dependOn(&run_golden.step);
    if (test_filters.len == 0) steps.@"test".dependOn(&run_golden.step);
}
