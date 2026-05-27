const std = @import("std");
const refresh_mod = @import("refresh");
const index_mod = refresh_mod.index;
const session_mod = refresh_mod.session;

test "refresh + allPickerRows ingests all three fixtures" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const db_path_unterm = try std.fmt.allocPrint(allocator, "{s}/index.sqlite", .{tmp_path});
    defer allocator.free(db_path_unterm);
    const db_path = try allocator.dupeZ(u8, db_path_unterm);
    defer allocator.free(db_path);

    var idx = try index_mod.Index.open(allocator, db_path);
    defer idx.close();

    try refresh_mod.refresh(allocator, &idx, .{
        .claude_root = "test/fixtures/claude/projects",
        .codex_root = "test/fixtures/codex/sessions",
        .gemini_tmp_root = "test/fixtures/gemini/tmp",
        .gemini_projects_json = "test/fixtures/gemini/projects.json",
    });

    const rows = try idx.allPickerRows(allocator);
    defer index_mod.freePickerRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 3), rows.len);

    var seen = std.EnumSet(session_mod.Agent).initEmpty();
    for (rows) |r| seen.insert(r.agent);
    try std.testing.expect(seen.contains(.claude));
    try std.testing.expect(seen.contains(.codex));
    try std.testing.expect(seen.contains(.gemini));
}
