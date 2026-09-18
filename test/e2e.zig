const std = @import("std");
const refresh_mod = @import("refresh");
const index_mod = refresh_mod.index;
const session_mod = refresh_mod.session;
const fass_exe = @import("build_options").fass_exe;

test "refresh + allPickerRows ingests all three fixtures" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const db_path_unterm = try std.fmt.allocPrint(allocator, "{s}/index.sqlite", .{tmp_path});
    defer allocator.free(db_path_unterm);
    const db_path = try allocator.dupeZ(u8, db_path_unterm);
    defer allocator.free(db_path);

    var idx = try index_mod.Index.open(allocator, db_path);
    defer idx.close();

    try refresh_mod.refresh(allocator, io, &idx, .{
        .claude_root = "test/fixtures/claude/projects",
        .codex_root = "test/fixtures/codex/sessions",
        .gemini_tmp_root = "test/fixtures/gemini/tmp",
        .gemini_projects_json = "test/fixtures/gemini/projects.json",
    }, null);

    const rows = try idx.allPickerRows(allocator);
    defer index_mod.freePickerRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 3), rows.len);

    var seen = std.EnumSet(session_mod.Agent).initEmpty();
    for (rows) |r| seen.insert(r.agent);
    try std.testing.expect(seen.contains(.claude));
    try std.testing.expect(seen.contains(.codex));
    try std.testing.expect(seen.contains(.gemini));
}

fn runFass(environ: ?*const std.process.Environ.Map, args: []const []const u8) !std.process.RunResult {
    const allocator = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, fass_exe);
    try argv.appendSlice(allocator, args);
    return std.process.run(allocator, std.testing.io, .{
        .argv = argv.items,
        .environ_map = environ,
    });
}

fn freeResult(result: std.process.RunResult) void {
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
}

test "CLI writes help to stdout and rejects unknown arguments" {
    const help = try runFass(null, &.{"--help"});
    defer freeResult(help);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, help.term);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "Usage:") != null);
    try std.testing.expectEqualStrings("", help.stderr);

    const invalid = try runFass(null, &.{"--unknown"});
    defer freeResult(invalid);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, invalid.term);
    try std.testing.expectEqualStrings("", invalid.stdout);
    try std.testing.expect(std.mem.indexOf(u8, invalid.stderr, "UnknownArg") != null);
}

test "CLI indexes an isolated HOME, filters, rebuilds, and previews cached prompts" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    const cache = try std.fs.path.join(allocator, &.{ home, "cache" });
    defer allocator.free(cache);
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", home);
    try environ.put("FASS_CACHE_DIR", cache);

    for ([_][]const u8{ "claude", "codex", "gemini" }) |agent| {
        const fixture = try std.fmt.allocPrint(allocator, "test/fixtures/{s}", .{agent});
        defer allocator.free(fixture);
        const absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, fixture, allocator);
        defer allocator.free(absolute);
        const link = try std.fmt.allocPrint(allocator, ".{s}", .{agent});
        defer allocator.free(link);
        try tmp.dir.symLink(io, absolute, link, .{ .is_directory = true });
    }

    const all = try runFass(&environ, &.{"--no-pick"});
    defer freeResult(all);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, all.term);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, all.stdout, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, all.stdout, "First prompt Second prompt") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, all.stderr, '\r') == null);

    const filtered = try runFass(&environ, &.{ "--no-pick", "--codex", "--reindex" });
    defer freeResult(filtered);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, filtered.term);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, filtered.stdout, "\n"));
    try std.testing.expect(std.mem.startsWith(u8, filtered.stdout, "codex\t"));

    try tmp.dir.deleteFile(io, ".claude");
    const preview = try runFass(&environ, &.{ "preview", "claude", "11111111-1111-1111-1111-111111111111" });
    defer freeResult(preview);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, preview.term);
    try std.testing.expect(std.mem.indexOf(u8, preview.stdout, "First prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, preview.stdout, "Second prompt") != null);
}

test "CLI resumes the selected agent through PATH in the session working directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    const cwd = try std.fs.path.join(allocator, &.{ home, "project" });
    defer allocator.free(cwd);
    const finder = try std.fs.path.join(allocator, &.{ home, "finder" });
    defer allocator.free(finder);
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", home);
    try environ.put("PATH", home);
    try environ.put("FASS_FINDER", finder);

    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.createDirPath(io, ".claude/projects");
    const transcript = try std.json.Stringify.valueAlloc(allocator, .{
        .type = "user",
        .message = .{ .role = "user", .content = "Resume this session" },
        .timestamp = "2026-05-01T10:00:00.000Z",
        .cwd = cwd,
    }, .{});
    defer allocator.free(transcript);
    try tmp.dir.writeFile(io, .{ .sub_path = ".claude/projects/resume-id.jsonl", .data = transcript });
    try tmp.dir.writeFile(io, .{
        .sub_path = "finder",
        .data = "#!/bin/sh\nexec /bin/cat\n",
        .flags = .{ .permissions = .fromMode(0o755) },
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "claude",
        .data = "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$1\" \"$2\"\n",
        .flags = .{ .permissions = .fromMode(0o755) },
    });

    const result = try runFass(&environ, &.{});
    defer freeResult(result);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    const expected = try std.fmt.allocPrint(allocator, "{s}\n--resume\nresume-id\n", .{cwd});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result.stdout);
}
