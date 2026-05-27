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

/// Optional progress sink. `update` is called once with `done=0` right after an
/// agent's files are discovered (so the consumer learns the total), then once
/// per file iterated regardless of whether it was re-parsed or skipped.
/// `finish` is called once after all three agents are done — the consumer
/// uses it to clear any in-place display before the picker takes over.
pub const Progress = struct {
    ctx: *anyopaque,
    update: *const fn (ctx: *anyopaque, agent: session.Agent, done: usize, total: usize) void,
    finish: *const fn (ctx: *anyopaque) void,
};

pub fn refresh(
    allocator: std.mem.Allocator,
    idx: *index_mod.Index,
    roots: Roots,
    progress: ?Progress,
) !void {
    var kept_paths: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (kept_paths.items) |p| allocator.free(p);
        kept_paths.deinit(allocator);
    }

    // Discover all three agents up front so progress totals are known from
    // the first render. Without this, the gemini row sat at 0/0 for the
    // duration of the (much larger) claude and codex passes, which read as
    // "no gemini sessions found" even though discovery hadn't run yet.
    const claude_refs = try claude.discover(allocator, roots.claude_root);
    defer {
        for (claude_refs) |r| allocator.free(r.path);
        allocator.free(claude_refs);
    }
    const codex_refs = try codex.discover(allocator, roots.codex_root);
    defer {
        for (codex_refs) |r| allocator.free(r.path);
        allocator.free(codex_refs);
    }
    const gemini_refs = try gemini.discover(allocator, roots.gemini_tmp_root);
    defer {
        for (gemini_refs) |r| allocator.free(r.path);
        allocator.free(gemini_refs);
    }

    if (progress) |p| {
        p.update(p.ctx, .claude, 0, claude_refs.len);
        p.update(p.ctx, .codex, 0, codex_refs.len);
        p.update(p.ctx, .gemini, 0, gemini_refs.len);
    }

    try ingestClaude(allocator, idx, claude_refs, &kept_paths, progress);
    try ingestCodex(allocator, idx, codex_refs, &kept_paths, progress);
    try ingestGemini(allocator, idx, gemini_refs, roots.gemini_projects_json, &kept_paths, progress);

    const keep_slices = try allocator.alloc([]const u8, kept_paths.items.len);
    defer allocator.free(keep_slices);
    for (kept_paths.items, 0..) |p, i| keep_slices[i] = p;

    try idx.pruneMissing(keep_slices);

    if (progress) |p| p.finish(p.ctx);
}

fn ingestClaude(
    allocator: std.mem.Allocator,
    idx: *index_mod.Index,
    refs: []const claude.FileRef,
    kept: *std.ArrayListUnmanaged([]u8),
    progress: ?Progress,
) !void {
    const total = refs.len;
    for (refs, 0..) |r, i| {
        try kept.append(allocator, try allocator.dupe(u8, r.path));
        const existing = try idx.getMtime(r.path);
        if (existing) |m| if (m >= r.mtime_unix) {
            if (progress) |p| p.update(p.ctx, .claude, i + 1, total);
            continue;
        };
        if (claude.parse(allocator, r.path)) |sess| {
            defer claude.freeSession(allocator, sess);
            try idx.upsertSession(sess);
        } else |err| {
            logParseError(.claude, r.path, err);
        }
        if (progress) |p| p.update(p.ctx, .claude, i + 1, total);
    }
}

fn ingestCodex(
    allocator: std.mem.Allocator,
    idx: *index_mod.Index,
    refs: []const codex.FileRef,
    kept: *std.ArrayListUnmanaged([]u8),
    progress: ?Progress,
) !void {
    const total = refs.len;
    for (refs, 0..) |r, i| {
        try kept.append(allocator, try allocator.dupe(u8, r.path));
        const existing = try idx.getMtime(r.path);
        if (existing) |m| if (m >= r.mtime_unix) {
            if (progress) |p| p.update(p.ctx, .codex, i + 1, total);
            continue;
        };
        if (codex.parse(allocator, r.path)) |sess| {
            defer codex.freeSession(allocator, sess);
            try idx.upsertSession(sess);
        } else |err| {
            logParseError(.codex, r.path, err);
        }
        if (progress) |p| p.update(p.ctx, .codex, i + 1, total);
    }
}

fn ingestGemini(
    allocator: std.mem.Allocator,
    idx: *index_mod.Index,
    refs: []const gemini.FileRef,
    projects_json: []const u8,
    kept: *std.ArrayListUnmanaged([]u8),
    progress: ?Progress,
) !void {
    var projects = try gemini.loadProjectsMap(allocator, projects_json);
    defer gemini.freeProjectsMap(allocator, &projects);

    const total = refs.len;
    for (refs, 0..) |r, i| {
        try kept.append(allocator, try allocator.dupe(u8, r.path));
        const existing = try idx.getMtime(r.path);
        if (existing) |m| if (m >= r.mtime_unix) {
            if (progress) |p| p.update(p.ctx, .gemini, i + 1, total);
            continue;
        };
        if (gemini.parse(allocator, r.path, &projects)) |sess| {
            defer gemini.freeSession(allocator, sess);
            try idx.upsertSession(sess);
        } else |err| {
            logParseError(.gemini, r.path, err);
        }
        if (progress) |p| p.update(p.ctx, .gemini, i + 1, total);
    }
}

test "refresh announces every agent's total before any per-file tick" {
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

    const Recorder = struct {
        events: std.ArrayListUnmanaged(struct { agent: session.Agent, done: usize, total: usize }) = .empty,
        allocator: std.mem.Allocator,

        fn update(ctx: *anyopaque, agent: session.Agent, done: usize, total: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.events.append(self.allocator, .{ .agent = agent, .done = done, .total = total }) catch unreachable;
        }
        fn finish(_: *anyopaque) void {}
    };

    var recorder = Recorder{ .allocator = allocator };
    defer recorder.events.deinit(allocator);

    try refresh(allocator, &idx, .{
        .claude_root = "test/fixtures/claude/projects",
        .codex_root = "test/fixtures/codex/sessions",
        .gemini_tmp_root = "test/fixtures/gemini/tmp",
        .gemini_projects_json = "test/fixtures/gemini/projects.json",
    }, .{ .ctx = &recorder, .update = Recorder.update, .finish = Recorder.finish });

    // The regression we're guarding against: gemini's total stayed at 0/0
    // for the entire duration of the claude+codex passes. Assert ordering
    // directly — every agent's initial (done=0) announcement must precede
    // the first per-file tick across all agents. No assertion on totals
    // being non-zero, since an agent with no sessions legitimately gets 0.
    var first_announce: [3]?usize = .{ null, null, null };
    var first_tick: ?usize = null;
    for (recorder.events.items, 0..) |e, i| {
        const slot: usize = switch (e.agent) {
            .claude => 0,
            .codex => 1,
            .gemini => 2,
        };
        if (e.done == 0 and first_announce[slot] == null) first_announce[slot] = i;
        if (e.done > 0 and first_tick == null) first_tick = i;
    }
    try std.testing.expect(first_announce[0] != null);
    try std.testing.expect(first_announce[1] != null);
    try std.testing.expect(first_announce[2] != null);
    if (first_tick) |t| {
        try std.testing.expect(first_announce[0].? < t);
        try std.testing.expect(first_announce[1].? < t);
        try std.testing.expect(first_announce[2].? < t);
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
    }, null);

    const rows = try idx.allPickerRows(allocator);
    defer index_mod.freePickerRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 3), rows.len);
}
