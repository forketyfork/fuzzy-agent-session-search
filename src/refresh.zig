const std = @import("std");
const index_mod = @import("index.zig");
const claude = @import("adapters/claude.zig");
const codex = @import("adapters/codex.zig");
const gemini = @import("adapters/gemini.zig");

const log = std.log.scoped(.refresh);

pub const index = index_mod;
pub const session = @import("session.zig");

/// `EmptySession` means the file is a genuine no-content session (e.g. the
/// user started an agent and exited before sending a prompt). Nothing to log
/// at warn level — surface at debug only. Any other parse failure (malformed
/// JSON, missing required fields) is a real anomaly and stays at warn.
fn logParseError(agent: session.Agent, path: []const u8, err: anyerror) void {
    if (err == error.EmptySession) {
        log.debug("{s}: empty session at {s}", .{ agent.toString(), path });
    } else {
        log.warn("{s} parse failed for {s}: {s}", .{ agent.toString(), path, @errorName(err) });
    }
}

pub const Roots = struct {
    claude_root: []const u8,
    codex_root: []const u8,
    gemini_tmp_root: []const u8,
    gemini_projects_json: []const u8,
};

pub fn refresh(allocator: std.mem.Allocator, idx: *index_mod.Index, roots: Roots) !void {
    var kept_paths: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (kept_paths.items) |p| allocator.free(p);
        kept_paths.deinit(allocator);
    }

    try ingestClaude(allocator, idx, roots.claude_root, &kept_paths);
    try ingestCodex(allocator, idx, roots.codex_root, &kept_paths);
    try ingestGemini(allocator, idx, roots.gemini_tmp_root, roots.gemini_projects_json, &kept_paths);

    const keep_slices = try allocator.alloc([]const u8, kept_paths.items.len);
    defer allocator.free(keep_slices);
    for (kept_paths.items, 0..) |p, i| keep_slices[i] = p;

    try idx.pruneMissing(keep_slices);
}

fn ingestClaude(
    allocator: std.mem.Allocator,
    idx: *index_mod.Index,
    root: []const u8,
    kept: *std.ArrayListUnmanaged([]u8),
) !void {
    const refs = try claude.discover(allocator, root);
    defer {
        for (refs) |r| allocator.free(r.path);
        allocator.free(refs);
    }
    for (refs) |r| {
        try kept.append(allocator, try allocator.dupe(u8, r.path));
        const existing = try idx.getMtime(r.path);
        if (existing) |m| if (m >= r.mtime_unix) continue;
        const sess = claude.parse(allocator, r.path) catch |err| {
            logParseError(.claude, r.path, err);
            continue;
        };
        defer claude.freeSession(allocator, sess);
        try idx.upsertSession(sess);
    }
}

fn ingestCodex(
    allocator: std.mem.Allocator,
    idx: *index_mod.Index,
    root: []const u8,
    kept: *std.ArrayListUnmanaged([]u8),
) !void {
    const refs = try codex.discover(allocator, root);
    defer {
        for (refs) |r| allocator.free(r.path);
        allocator.free(refs);
    }
    for (refs) |r| {
        try kept.append(allocator, try allocator.dupe(u8, r.path));
        const existing = try idx.getMtime(r.path);
        if (existing) |m| if (m >= r.mtime_unix) continue;
        const sess = codex.parse(allocator, r.path) catch |err| {
            logParseError(.codex, r.path, err);
            continue;
        };
        defer codex.freeSession(allocator, sess);
        try idx.upsertSession(sess);
    }
}

fn ingestGemini(
    allocator: std.mem.Allocator,
    idx: *index_mod.Index,
    root: []const u8,
    projects_json: []const u8,
    kept: *std.ArrayListUnmanaged([]u8),
) !void {
    var projects = try gemini.loadProjectsMap(allocator, projects_json);
    defer gemini.freeProjectsMap(allocator, &projects);

    const refs = try gemini.discover(allocator, root);
    defer {
        for (refs) |r| allocator.free(r.path);
        allocator.free(refs);
    }
    for (refs) |r| {
        try kept.append(allocator, try allocator.dupe(u8, r.path));
        const existing = try idx.getMtime(r.path);
        if (existing) |m| if (m >= r.mtime_unix) continue;
        const sess = gemini.parse(allocator, r.path, &projects) catch |err| {
            logParseError(.gemini, r.path, err);
            continue;
        };
        defer gemini.freeSession(allocator, sess);
        try idx.upsertSession(sess);
    }
}

test "refresh ingests fixtures from all three agents" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const db_path_str = try std.fmt.allocPrint(allocator, "{s}/i.sqlite", .{tmp_path});
    defer allocator.free(db_path_str);
    const db_path: [:0]u8 = try allocator.dupeZ(u8, db_path_str);
    defer allocator.free(db_path);

    var idx = try index_mod.Index.open(allocator, db_path);
    defer idx.close();

    try refresh(allocator, &idx, .{
        .claude_root = "test/fixtures/claude/projects",
        .codex_root = "test/fixtures/codex/sessions",
        .gemini_tmp_root = "test/fixtures/gemini/tmp",
        .gemini_projects_json = "test/fixtures/gemini/projects.json",
    });

    const rows = try idx.allPickerRows(allocator);
    defer index_mod.freePickerRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 3), rows.len);
}
