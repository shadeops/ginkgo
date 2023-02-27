const std = @import("std");

const raylib_build = @import("deps/raylib/src/build.zig");

pub fn addRayguiLib(b: *std.Build, target: std.zig.CrossTarget, optimize: std.builtin.OptimizeMode) *std.Build.CompileStep {
    const raygui_flags = &[_][]const u8{
        "-std=gnu99",
        "-D_GNU_SOURCE",
        "-DGL_SILENCE_DEPRECATION=199309L",
        "-fno-sanitize=undefined", // https://github.com/raysan5/raylib/issues/1891
        "-DRAYGUI_IMPLEMENTATION",
    };

    const raygui = b.addStaticLibrary(.{
        .name = "raygui",
        .target = target,
        .optimize = optimize,
    });
    raygui.linkLibC();
    raygui.addIncludePath("deps/raylib/src");
    raygui.addIncludePath("deps/raygui/src");
    raygui.addCSourceFiles(&.{
        "raygui_wrapper/raygui_wrapper.c",
    }, raygui_flags);

    return raygui;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const raylib = raylib_build.addRaylib(b, target, optimize);
    const raygui = addRayguiLib(b, target, optimize);

    const exe = b.addExecutable(.{
        .name = "ginkgo",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibrary(raylib);
    exe.linkLibrary(raygui);
    exe.addIncludePath("deps/raylib/src");
    exe.addIncludePath("deps/raygui/src");
    exe.linkLibC();
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
