const std = @import("std");
const index_mod = @import("index.zig");

const log = std.log.scoped(.picker);

/// Renders one picker line per row. The output uses TAB as a field separator
/// and ends each row with '\n'.
///
/// Columns:
///   1. agent
///   2. date (YYYY-MM-DD HH:MM, UTC)
///   3. cwd-abbrev (HOME -> ~, left-truncated to 40)
///   4. search corpus — all user prompts joined, newlines stripped
///   5. id (hidden from display via --with-nth, used by preview/resume)
///
/// fzf is invoked with `--with-nth=1,2,3,4` so the id column doesn't show.
/// We deliberately do NOT use `--nth=N`: with `--with-nth` it would operate on
/// the transformed line, breaking matching against the corpus.
pub fn renderRows(
    allocator: std.mem.Allocator,
    writer: anytype,
    rows: []const index_mod.PickerRow,
    home: ?[]const u8,
) !void {
    log.debug("rendering {d} picker row(s)", .{rows.len});
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(allocator);

    for (rows) |r| {
        line.clearRetainingCapacity();

        try line.appendSlice(allocator, r.agent.toString());
        try line.append(allocator, '\t');

        try appendDate(allocator, &line, r.started_at_unix);
        try line.append(allocator, '\t');

        try appendCwdAbbrev(allocator, &line, r.cwd, home);
        try line.append(allocator, '\t');

        try appendOneLine(allocator, &line, r.search_corpus);
        try line.append(allocator, '\t');

        try line.appendSlice(allocator, r.id);
        try line.append(allocator, '\n');

        try writer.writeAll(line.items);
    }
}

fn appendDate(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), unix_seconds: i64) !void {
    var s = unix_seconds;
    const days = @divFloor(s, 86400);
    s -= days * 86400;
    const hour: u32 = @intCast(@divFloor(s, 3600));
    s -= @as(i64, hour) * 3600;
    const minute: u32 = @intCast(@divFloor(s, 60));

    const z = days + 719468;
    const era = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
    const doe: u32 = @intCast(z - era * 146097);
    const yoe: u32 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y: i32 = @intCast(@as(i64, yoe) + era * 400);
    const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u32 = (5 * doy + 2) / 153;
    const d: u32 = doy - (153 * mp + 2) / 5 + 1;
    const m: u32 = if (mp < 10) mp + 3 else mp - 9;
    const year: i32 = if (m <= 2) y + 1 else y;

    const year_u: u32 = @intCast(year);
    try buf.writer(allocator).print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ year_u, m, d, hour, minute });
}

fn appendCwdAbbrev(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    cwd: ?[]const u8,
    home: ?[]const u8,
) !void {
    const c_cwd = cwd orelse {
        try buf.appendSlice(allocator, "-");
        return;
    };
    var s = c_cwd;
    if (home) |h| if (std.mem.startsWith(u8, s, h)) {
        try buf.append(allocator, '~');
        s = s[h.len..];
    };
    const max = 40;
    if (s.len > max) {
        try buf.appendSlice(allocator, "…");
        try buf.appendSlice(allocator, s[s.len - (max - 1) ..]);
    } else {
        try buf.appendSlice(allocator, s);
    }
}

fn appendOneLine(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    for (text) |ch| {
        const safe: u8 = switch (ch) {
            '\n', '\r', '\t' => ' ',
            else => ch,
        };
        try buf.append(allocator, safe);
    }
}

pub const PickError = error{
    FinderNotFound,
    FinderFailed,
    NoSelection,
};

pub const Spawned = struct {
    selection: []u8, // owned by allocator
};

pub fn runFinder(
    allocator: std.mem.Allocator,
    finder_argv: []const []const u8,
    input: []const u8,
) !Spawned {
    var child = std.process.Child.init(finder_argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    child.spawn() catch |err| switch (err) {
        error.FileNotFound => return PickError.FinderNotFound,
        else => return err,
    };
    errdefer _ = child.kill() catch |err| log.debug("kill failed: {}", .{err});

    if (child.stdin) |stdin| {
        stdin.writeAll(input) catch |err| log.debug("stdin write failed: {}", .{err});
        stdin.close();
        child.stdin = null;
    }

    const stdout_data: []u8 = if (child.stdout) |stdout|
        try stdout.readToEndAlloc(allocator, 16 * 1024 * 1024)
    else
        try allocator.dupe(u8, "");
    defer allocator.free(stdout_data);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return PickError.FinderFailed,
        else => return PickError.FinderFailed,
    }

    var it = std.mem.splitScalar(u8, stdout_data, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        return .{ .selection = try allocator.dupe(u8, trimmed) };
    }
    return PickError.NoSelection;
}

test "runFinder pipes input to the finder and reads selected line back" {
    const allocator = std.testing.allocator;
    const result = try runFinder(allocator, &.{"/bin/cat"}, "alpha\nbeta\ngamma\n");
    defer allocator.free(result.selection);
    try std.testing.expectEqualStrings("alpha", result.selection);
}

test "renderRows emits one tab-separated line per row" {
    const rows = [_]index_mod.PickerRow{
        .{
            .agent = .claude,
            .started_at_unix = 1700000000, // 2023-11-14 22:13 UTC
            .cwd = "/Users/alice/dev/foo",
            .first_prompt = "Please refactor\nthis file",
            .id = "11111111",
            .search_corpus = "Please refactor this file later too",
        },
    };
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer = buf.writer(std.testing.allocator);
    try renderRows(std.testing.allocator, &writer, &rows, "/Users/alice");

    const out = buf.items;
    try std.testing.expect(std.mem.startsWith(u8, out, "claude\t"));
    try std.testing.expect(std.mem.indexOf(u8, out, "~/dev/foo") != null);
    // The displayed snippet now comes from search_corpus (column 4), not the
    // separate first_prompt. The corpus is already newline-stripped upstream.
    try std.testing.expect(std.mem.indexOf(u8, out, "Please refactor this file later too") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "11111111\n"));
    // Five columns: agent, date, cwd, corpus, id → four tab separators.
    var tab_count: usize = 0;
    for (out) |ch| if (ch == '\t') {
        tab_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 4), tab_count);
}
