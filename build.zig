const std = @import("std");

pub fn build(b: *std.Build) !void {
    // Get the cmd target and optimization options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Lib path selection using target information
    const tri = try target.linuxTriple(b.allocator);
    defer b.allocator.free(tri);
    const lib_path = try std.fmt.allocPrint(b.allocator, "lib/{s}", .{tri});
    defer b.allocator.free(lib_path);

    const tflib_name = "tensorflowlite_c";
    const wrtclib_name = "webrtcnoisegain_c";

    // Modules
    const clap_mod = b.dependency("clap", .{}).module("clap");
    const serial_mod = b.dependency("serial", .{}).module("serial");
    const gpio_mod = b.dependency("gpio", .{}).module("gpio");

    // oww-mini exe
    const exe = b.addExecutable(.{
        .name = "voz-oww",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addIncludePath(.{ .path = "lib/include" });
    exe.addLibraryPath(.{ .path = lib_path });
    exe.linkSystemLibraryName(tflib_name);
    exe.linkSystemLibraryName(wrtclib_name);
    exe.linkLibC();
    // Add modules
    exe.addModule("clap", clap_mod);

    // Pre-processor executable
    const exe_pre = b.addExecutable(.{
        .name = "voz-pre",
        .root_source_file = .{ .path = "src/main-pre.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe_pre.addIncludePath(.{ .path = "lib/include" });
    exe_pre.addLibraryPath(.{ .path = lib_path });
    exe_pre.linkSystemLibraryName(wrtclib_name);
    exe_pre.linkLibC();
    // Add modules
    exe_pre.addModule("clap", clap_mod);

    // Serial executable
    const exe_ser = b.addExecutable(.{
        .name = "voz-ser",
        .root_source_file = .{ .path = "src/main-ser.zig" },
        .target = target,
        .optimize = optimize,
    });
    // Add modules
    exe_ser.addModule("clap", clap_mod);
    exe_ser.addModule("serial", serial_mod);
    exe_ser.addModule("gpio", gpio_mod);

    // Install (deploy executables)
    b.installArtifact(exe_ser);
    b.installArtifact(exe_pre);
    b.installArtifact(exe);

    // Run & Test Helpers
    // ==================
    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    // TODO
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
