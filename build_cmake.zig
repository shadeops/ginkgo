const std = @import("std");

// TODO: We can't use deps/raylib/src/build.zig because it doesn't support
// building of the vendored glfw3 and looks for the system one. Which causes
// the compilation fails due to a missing X11/Xlib.h when cross compiling
// for a different version of glibc ie)
// -Dtarget=x86_64-linux-gnu.2.17
//

fn buildRaylib(b: *std.build.Builder) *std.build.RunStep {
    const cmake = b.addSystemCommand(&[_][]const u8{
        "cmake",
        "-B",
        "deps/raylib/build",
        "-S",
        "deps/raylib",
        "-DCMAKE_BUILD_TYPE=Release",
        "-DOpenGL_GL_PREFERENCE=GLVND",
        "-DBUILD_EXAMPLES=OFF",
    });
    const cmake_build = b.addSystemCommand(&[_][]const u8{
        "cmake",
        "--build",
        "deps/raylib/build",
        "--",
        "-j",
        "16",
    });
    cmake_build.step.dependOn(&cmake.step);
    return cmake_build;
}

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

    const build_ext = b.step("build-ext", "Build External Dependencies");
    build_ext.dependOn(&buildRaylib(b).step);

    const raygui = addRayguiLib(b, target, optimize);

    const exe = b.addExecutable(.{
        .name = "ginkgo",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addObjectFile("deps/raylib/build/raylib/libraylib.a");
    exe.linkLibrary(raygui);
    exe.addIncludePath("deps/raylib/src");
    exe.addIncludePath("deps/raygui/src");

    exe.linkLibC();
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.expected_term = null;

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
