const std = @import("std");
const session = @import("session.zig");
const claude = @import("adapters/claude.zig");
const codex = @import("adapters/codex.zig");
const gemini = @import("adapters/gemini.zig");
const index_mod = @import("index.zig");
const refresh_mod = @import("refresh.zig");
const picker = @import("picker.zig");
const resume_mod = @import("resume.zig");

const log = std.log.scoped(.main);

/// Renders refresh progress to stderr in-place when stderr is a TTY.
/// One line per agent; `\r` overwrites between updates. `finish` clears
/// the line so the picker (or any downstream output) starts on a clean row.
const ProgressCtx = struct {
    counts: [3]struct { done: usize = 0, total: usize = 0 } = .{ .{}, .{}, .{} },

    fn agentIdx(agent: session.Agent) usize {
        return switch (agent) {
            .claude => 0,
            .codex => 1,
            .gemini => 2,
        };
    }

    fn render(self: *ProgressCtx) void {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "\rindexing: claude {d}/{d}  codex {d}/{d}  gemini {d}/{d}",
            .{
                self.counts[0].done, self.counts[0].total,
                self.counts[1].done, self.counts[1].total,
                self.counts[2].done, self.counts[2].total,
            },
        ) catch |err| {
            log.debug("progress format: {}", .{err});
            return;
        };
        std.fs.File.stderr().writeAll(msg) catch |err| log.debug("progress write: {}", .{err});
    }

    fn update(ctx: *anyopaque, agent: session.Agent, done: usize, total: usize) void {
        const self: *ProgressCtx = @ptrCast(@alignCast(ctx));
        self.counts[agentIdx(agent)] = .{ .done = done, .total = total };
        self.render();
    }

    fn finish(_: *anyopaque) void {
        // Clear the current line: CR, then ANSI "erase to end of line".
        std.fs.File.stderr().writeAll("\r\x1b[K") catch |err| log.debug("progress clear: {}", .{err});
    }
};

pub const Opts = struct {
    agents: AgentFilter = .all,
    reindex: bool = false,
    no_pick: bool = false,
    preview: ?PreviewArgs = null,

    pub const AgentFilter = union(enum) {
        all,
        only: std.EnumSet(session.Agent),
    };

    pub const PreviewArgs = struct {
        agent: session.Agent,
        id_or_path: []const u8,
    };
};

pub fn parseArgs(allocator: std.mem.Allocator, raw: []const []const u8) !Opts {
    var opts = Opts{};
    var only = std.EnumSet(session.Agent).initEmpty();
    var any_filter = false;

    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const a = raw[i];
        if (std.mem.eql(u8, a, "--claude")) {
            only.insert(.claude);
            any_filter = true;
        } else if (std.mem.eql(u8, a, "--codex")) {
            only.insert(.codex);
            any_filter = true;
        } else if (std.mem.eql(u8, a, "--gemini")) {
            only.insert(.gemini);
            any_filter = true;
        } else if (std.mem.eql(u8, a, "--reindex")) {
            opts.reindex = true;
        } else if (std.mem.eql(u8, a, "--no-pick")) {
            opts.no_pick = true;
        } else if (std.mem.eql(u8, a, "preview")) {
            if (i + 2 >= raw.len) return error.PreviewArgs;
            const ag = session.Agent.fromString(raw[i + 1]) orelse return error.PreviewArgs;
            const id = try allocator.dupe(u8, raw[i + 2]);
            opts.preview = .{ .agent = ag, .id_or_path = id };
            i += 2;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            return error.HelpRequested;
        } else {
            return error.UnknownArg;
        }
    }

    if (any_filter) opts.agents = .{ .only = only };
    return opts;
}

test "parseArgs handles agent filters" {
    const allocator = std.testing.allocator;
    const opts = try parseArgs(allocator, &.{ "--claude", "--codex" });
    switch (opts.agents) {
        .only => |s| {
            try std.testing.expect(s.contains(.claude));
            try std.testing.expect(s.contains(.codex));
            try std.testing.expect(!s.contains(.gemini));
        },
        .all => unreachable,
    }
}

test "parseArgs reads preview subcommand" {
    const allocator = std.testing.allocator;
    const opts = try parseArgs(allocator, &.{ "preview", "claude", "uuid-1" });
    defer if (opts.preview) |p| allocator.free(p.id_or_path);
    try std.testing.expectEqual(session.Agent.claude, opts.preview.?.agent);
    try std.testing.expectEqualStrings("uuid-1", opts.preview.?.id_or_path);
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const opts = parseArgs(allocator, argv[1..]) catch |err| {
        switch (err) {
            error.HelpRequested => {
                try printHelp();
                return;
            },
            else => {
                var buf: [128]u8 = undefined;
                const msg = try std.fmt.bufPrint(&buf, "fass: argument error: {s}\n", .{@errorName(err)});
                try std.fs.File.stderr().writeAll(msg);
                std.process.exit(2);
            },
        }
    };

    try dispatch(allocator, opts);
}

fn printHelp() !void {
    try std.fs.File.stdout().writeAll(
        \\fuzzy-agent-session-search (fass) — unified picker for Claude Code, Codex, and Gemini sessions.
        \\
        \\Usage:
        \\  fass                          pick across all agents
        \\  fass --claude --codex         filter to specific agents (repeatable)
        \\  fass --reindex                drop the cache and rebuild
        \\  fass --no-pick                print the index to stdout instead of picking
        \\  fass preview <agent> <token>  internal, invoked by fzf
        \\
        \\Env:
        \\  FASS_FINDER     fzf | sk     (default: fzf, falling back to sk)
        \\  FASS_CACHE_DIR  directory for the cache (default: ~/.cache/fass)
        \\
    );
}

fn dispatch(allocator: std.mem.Allocator, opts: Opts) !void {
    defer if (opts.preview) |p| allocator.free(p.id_or_path);

    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    const cache_dir = try resolveCacheDir(allocator, home);
    defer allocator.free(cache_dir);
    try std.fs.cwd().makePath(cache_dir);

    const db_path_str = try std.fmt.allocPrint(allocator, "{s}/index.sqlite", .{cache_dir});
    defer allocator.free(db_path_str);
    const db_path: [:0]u8 = try allocator.dupeZ(u8, db_path_str);
    defer allocator.free(db_path);

    if (opts.reindex) std.fs.cwd().deleteFile(db_path) catch |err| {
        log.debug("delete cache db: {}", .{err});
    };

    var idx = try index_mod.Index.open(allocator, db_path);
    defer idx.close();

    // Preview is invoked once per focused row by fzf — fast path. Skip
    // refresh: the parent `fass` invocation already populated the index
    // before launching fzf, and re-running refresh here would re-emit parse
    // warnings on every keystroke into the preview pane.
    if (opts.preview) |p| {
        try runPreview(allocator, &idx, p.agent, p.id_or_path);
        return;
    }

    const roots = try buildRoots(allocator, home);
    defer freeRoots(allocator, roots);

    var progress_ctx = ProgressCtx{};
    const stderr_tty = std.fs.File.stderr().isTty();
    const progress: ?refresh_mod.Progress = if (stderr_tty)
        .{ .ctx = &progress_ctx, .update = ProgressCtx.update, .finish = ProgressCtx.finish }
    else
        null;
    try refresh_mod.refresh(allocator, &idx, roots, progress);

    const rows_all = try idx.allPickerRows(allocator);
    defer index_mod.freePickerRows(allocator, rows_all);
    const rows = try filterByAgentAlloc(allocator, rows_all, opts.agents);
    defer allocator.free(rows);

    if (opts.no_pick) {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        var w = buf.writer(allocator);
        try picker.renderRows(allocator, &w, rows, home);
        try std.fs.File.stdout().writeAll(buf.items);
        return;
    }

    try runPicker(allocator, rows, home, &idx);
}

fn filterByAgentAlloc(
    allocator: std.mem.Allocator,
    rows: []const index_mod.PickerRow,
    filter: Opts.AgentFilter,
) ![]index_mod.PickerRow {
    return switch (filter) {
        .all => try allocator.dupe(index_mod.PickerRow, rows),
        .only => |set| blk: {
            var out: std.ArrayListUnmanaged(index_mod.PickerRow) = .empty;
            errdefer out.deinit(allocator);
            for (rows) |row| {
                if (set.contains(row.agent)) try out.append(allocator, row);
            }
            break :blk try out.toOwnedSlice(allocator);
        },
    };
}

test "filterByAgent retains only requested agents" {
    const allocator = std.testing.allocator;
    const rows = [_]index_mod.PickerRow{
        .{ .agent = .claude, .started_at_unix = 0, .cwd = null, .first_prompt = "", .id = "1", .search_corpus = "" },
        .{ .agent = .codex, .started_at_unix = 0, .cwd = null, .first_prompt = "", .id = "2", .search_corpus = "" },
        .{ .agent = .gemini, .started_at_unix = 0, .cwd = null, .first_prompt = "", .id = "3", .search_corpus = "" },
    };
    var set = std.EnumSet(session.Agent).initEmpty();
    set.insert(.codex);
    const filtered = try filterByAgentAlloc(allocator, &rows, .{ .only = set });
    defer allocator.free(filtered);
    try std.testing.expectEqual(@as(usize, 1), filtered.len);
    try std.testing.expectEqual(session.Agent.codex, filtered[0].agent);
}

fn resolveCacheDir(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    if (std.posix.getenv("FASS_CACHE_DIR")) |c| return allocator.dupe(u8, c);
    return std.fmt.allocPrint(allocator, "{s}/.cache/fass", .{home});
}

fn buildRoots(allocator: std.mem.Allocator, home: []const u8) !refresh_mod.Roots {
    return .{
        .claude_root = try std.fmt.allocPrint(allocator, "{s}/.claude/projects", .{home}),
        .codex_root = try std.fmt.allocPrint(allocator, "{s}/.codex/sessions", .{home}),
        .gemini_tmp_root = try std.fmt.allocPrint(allocator, "{s}/.gemini/tmp", .{home}),
        .gemini_projects_json = try std.fmt.allocPrint(allocator, "{s}/.gemini/projects.json", .{home}),
    };
}

fn freeRoots(allocator: std.mem.Allocator, r: refresh_mod.Roots) void {
    allocator.free(r.claude_root);
    allocator.free(r.codex_root);
    allocator.free(r.gemini_tmp_root);
    allocator.free(r.gemini_projects_json);
}

fn runPreview(
    allocator: std.mem.Allocator,
    idx: *index_mod.Index,
    agent: session.Agent,
    id_or_path: []const u8,
) !void {
    const prompts = try idx.previewPrompts(allocator, agent, id_or_path, 20);
    defer index_mod.freePreviewPrompts(allocator, prompts);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    for (prompts) |p| {
        try buf.writer(allocator).print("[{d}] {s}\n\n", .{ p.ts, p.text });
    }
    try std.fs.File.stdout().writeAll(buf.items);
}

fn runPicker(
    allocator: std.mem.Allocator,
    rows: []const index_mod.PickerRow,
    home: []const u8,
    idx: *index_mod.Index,
) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);
    try picker.renderRows(allocator, &w, rows, home);

    const exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe);

    const finder = std.posix.getenv("FASS_FINDER") orelse "fzf";

    const preview_cmd = try std.fmt.allocPrint(allocator, "{s} preview {{1}} {{5}}", .{exe});
    defer allocator.free(preview_cmd);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        finder,
        "--delimiter=\t",
        // Hide the id column (5) from display. We do NOT use --nth: fzf
        // applies --nth to the post-with-nth transformed line, so the search
        // scope is already columns 1..4 (agent, date, cwd, search corpus).
        "--with-nth=1,2,3,4",
        "--ansi",
        "--no-sort",
        "--tac",
        "--preview-window=right:50%:wrap",
    });
    try argv.append(allocator, "--preview");
    try argv.append(allocator, preview_cmd);

    const sel = try picker.runFinder(allocator, argv.items, buf.items);
    defer allocator.free(sel.selection);

    var fields = std.mem.splitScalar(u8, sel.selection, '\t');
    const agent_str = fields.next() orelse return error.MalformedSelection;
    const agent = session.Agent.fromString(agent_str) orelse return error.MalformedSelection;
    _ = fields.next(); // date
    _ = fields.next(); // cwd-abbrev
    _ = fields.next(); // search corpus
    const id = fields.next() orelse return error.MalformedSelection;

    const cwd = try idx.lookupCwd(allocator, agent, id);
    defer if (cwd) |s| allocator.free(s);

    const sp = resume_mod.ExecSpawner.spawner();
    try resume_mod.resumeSession(sp, agent, id, cwd, allocator);
}

test {
    std.testing.refAllDecls(@This());
    _ = session;
    _ = claude;
    _ = codex;
    _ = gemini;
    _ = index_mod;
    _ = picker;
    _ = resume_mod;
    _ = refresh_mod;
}
