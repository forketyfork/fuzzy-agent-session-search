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

    const src_refresh = b.createModule(.{
        .root_source_file = b.path("src/refresh.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSqlite(b, src_refresh);

    const e2e_module = b.createModule(.{
        .root_source_file = b.path("test/e2e.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_module.addImport("refresh", src_refresh);
    const e2e_tests = b.addTest(.{ .root_module = e2e_module });
    const run_e2e = b.addRunArtifact(e2e_tests);
    const e2e_step = b.step("test-e2e", "Run end-to-end tests");
    e2e_step.dependOn(&run_e2e.step);
    test_step.dependOn(&run_e2e.step);

    const zwanzig_dep = b.dependency("zwanzig", .{
        .target = target,
        .optimize = optimize,
    });
    const zwanzig_exe = zwanzig_dep.artifact("zwanzig");

    const lint_cmd = b.addRunArtifact(zwanzig_exe);
    lint_cmd.addArgs(&.{ "--use-widening", "--skip", "deinit-lifecycle", "src/" });
    const lint_step = b.step("lint", "Run zwanzig over src/");
    lint_step.dependOn(&lint_cmd.step);

    const lint_sarif_cmd = b.addRunArtifact(zwanzig_exe);
    lint_sarif_cmd.addArgs(&.{ "--use-widening", "--skip", "deinit-lifecycle", "--format", "sarif", "src/" });
    const lint_sarif_step = b.step("lint-sarif", "Run zwanzig and emit SARIF on stdout");
    lint_sarif_step.dependOn(&lint_sarif_cmd.step);
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
