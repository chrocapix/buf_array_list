const std = @import("std");

pub fn build(b: *std.Build) !void {
    target = b.standardTargetOptions(.{});
    optimize = b.standardOptimizeOption(.{});

    const utilz = dependency(b, "utilz");

    const mod = addModule(b, "buf_array_list", .{
        .root_source_file = b.path("src/root.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "buf_array_list",
        .root_module = createModule(b, .{
            .root_source_file = b.path("src/main.zig"),
        }),
    });
    exe.root_module.addImport("buf_array_list", mod);
    exe.root_module.addImport("utilz.juice", utilz.module("juice"));
    exe.root_module.addImport("utilz.timer", utilz.module("timer"));

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args|
        run_exe.addArgs(args);
    const run_step = b.step("run", "Run the program");
    run_step.dependOn(&run_exe.step);

    // ------------ testing ------------

    const tests = b.step("test", "Run unit tests");

    const test1 = b.addTest(.{ .root_module = mod });
    const runtest1 = b.addRunArtifact(test1);
    tests.dependOn(&runtest1.step);

    // ------------ check ---------------
    const check = b.step("check", "");
    check.dependOn(&exe.step);
    check.dependOn(&test1.step);
}

var target: ?std.Build.ResolvedTarget = null;
var optimize: ?std.builtin.OptimizeMode = null;

pub fn dependency(
    b: *std.Build,
    name: []const u8,
) *std.Build.Dependency {
    if (target) |t|
        if (optimize) |o|
            return b.dependency(name, .{ .target = t, .optimize = o });
    if (target) |t|
        return b.dependency(name, .{ .target = t });
    if (optimize) |o|
        return b.dependency(name, .{ .optimize = o });
    return b.dependency(name, .{});
}

pub fn createModule(
    b: *std.Build,
    options: std.Build.Module.CreateOptions,
) *std.Build.Module {
    return b.createModule(moduleOptions(options));
}

pub fn addModule(
    b: *std.Build,
    name: []const u8,
    options: std.Build.Module.CreateOptions,
) *std.Build.Module {
    return b.addModule(name, moduleOptions(options));
}

fn moduleOptions(default: std.Build.Module.CreateOptions) std.Build.Module.CreateOptions {
    var options = default;
    if (options.target == null) {
        if (target) |t| options.target = t;
    }
    if (options.optimize == null) {
        if (optimize) |t| options.optimize = t;
    }
    return options;
}
