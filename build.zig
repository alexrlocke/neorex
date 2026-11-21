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

    // tests reach every file through main.zig's test block
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run tests");
    const run_tests = b.addRunArtifact(exe_tests);
    // src/lua_spec.zig runs test/lua from the repository's root; the Lua it
    // reads is listed so that changing it runs the tests again
    run_tests.setCwd(b.path("."));
    for ([_][]const u8{
        "runtime/lua/neorex/prompt.lua",
        "runtime/lua/neorex/ui.lua",
        "runtime/lua/neorex/pick.lua",
        "runtime/lua/neorex/health.lua",
        "runtime/rex/neorex.lua",
        "test/lua/prompt_spec.lua",
    }) |lua| run_tests.addFileInput(b.path(lua));
    test_step.dependOn(&run_tests.step);

    const rex_tests = b.addTest(.{ .root_module = rex_mod });
    const run_rex = b.addRunArtifact(rex_tests);
    test_step.dependOn(&run_rex.step);
    b.step("test-rex", "Run rex tests").dependOn(&run_rex.step);

    const term_tests = b.addTest(.{ .root_module = term_mod });
    const run_term = b.addRunArtifact(term_tests);
    test_step.dependOn(&run_term.step);
    b.step("test-term", "Run term tests").dependOn(&run_term.step);

    const msgpack_tests = b.addTest(.{ .root_module = msgpack_mod });
    const run_msgpack = b.addRunArtifact(msgpack_tests);
    test_step.dependOn(&run_msgpack.step);
    b.step("test-msgpack", "Run msgpack tests").dependOn(&run_msgpack.step);

    // integration tests: neorex's pieces against a real Neovim; each skips
    // when nvim isn't installed
    const integration_mod = b.createModule(.{
        .root_source_file = b.path("src/integration.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    integration_mod.addImport("msgpack", msgpack_mod);
    const integration_tests = b.addTest(.{ .root_module = integration_mod });
    const run_integration = b.addRunArtifact(integration_tests);
    test_step.dependOn(&run_integration.step);
    b.step("test-integration", "Run the tests that drive a real Neovim").dependOn(&run_integration.step);

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
    golden_mod.addImport("msgpack", msgpack_mod);
    const golden_tests = b.addTest(.{ .root_module = golden_mod });
    test_step.dependOn(&b.addRunArtifact(golden_tests).step);
}
