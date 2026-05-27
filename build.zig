const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSqlite(b, exe_module);

    const exe = b.addExecutable(.{
        .name = "fzag",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run fzag");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSqlite(b, test_module);
    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

fn linkSqlite(b: *std.Build, module: *std.Build.Module) void {
    module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=0",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_ENABLE_DBSTAT_VTAB=0",
            "-DSQLITE_USE_URI=1",
            "-std=c11",
            "-Wno-everything",
        },
    });
    module.addIncludePath(b.path("vendor/sqlite"));
    module.link_libc = true;
}
