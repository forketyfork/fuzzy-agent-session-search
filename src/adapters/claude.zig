const std = @import("std");
const session = @import("../session.zig");

const log = std.log.scoped(.claude);

pub const FileRef = struct {
    path: []const u8,
    mtime_unix: i64,
};

/// Walk `root` (typically `~/.claude/projects`) and return a slice of jsonl files.
pub fn discover(allocator: std.mem.Allocator, root: []const u8) ![]FileRef {
    var refs: std.ArrayListUnmanaged(FileRef) = .empty;
    errdefer {
        for (refs.items) |r| allocator.free(r.path);
        refs.deinit(allocator);
    }

    var root_dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return refs.toOwnedSlice(allocator),
        else => return err,
    };
    defer root_dir.close();

    var walker = try root_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".jsonl")) continue;
        // Claude Code stores subagent transcripts under <session-uuid>/subagents/.
        // They are sidechain-only and not resumable from the CLI, so skip them
        // at discovery time rather than parsing only to return EmptySession.
        if (std.mem.indexOf(u8, entry.path, "/subagents/") != null) continue;

        const abs_path = try std.fs.path.join(allocator, &.{ root, entry.path });
        errdefer allocator.free(abs_path);

        const stat = try entry.dir.statFile(entry.basename);
        try refs.append(allocator, .{
            .path = abs_path,
            .mtime_unix = @intCast(@divTrunc(stat.mtime, std.time.ns_per_s)),
        });
    }

    return refs.toOwnedSlice(allocator);
}

test "discover finds main sessions and skips subagents/" {
    const allocator = std.testing.allocator;
    const refs = try discover(allocator, "test/fixtures/claude/projects");
    defer {
        for (refs) |r| allocator.free(r.path);
        allocator.free(refs);
    }
    // The fixture tree contains one main session and one subagent JSONL under
    // a subagents/ directory. Only the main session is resumable, so we should
    // discover exactly one file.
    try std.testing.expectEqual(@as(usize, 1), refs.len);
    try std.testing.expect(std.mem.endsWith(u8, refs[0].path, "11111111-1111-1111-1111-111111111111.jsonl"));
    try std.testing.expect(std.mem.indexOf(u8, refs[0].path, "/subagents/") == null);
    try std.testing.expect(refs[0].mtime_unix > 0);
}

/// Parses a Claude JSONL file into a `Session`. All returned strings are
/// allocated from `allocator`.
pub fn parse(allocator: std.mem.Allocator, path: []const u8) !session.Session {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const contents = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(contents);

    var prompts: std.ArrayListUnmanaged(session.UserPrompt) = .empty;
    errdefer {
        for (prompts.items) |p| allocator.free(p.text);
        prompts.deinit(allocator);
    }

    var cwd_opt: ?[]u8 = null;
    errdefer if (cwd_opt) |c| allocator.free(c);

    var started_at_unix: i64 = 0;

    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            line,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            log.debug("skipping malformed line: {}", .{err});
            continue;
        };
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };

        const t = (obj.get("type") orelse continue);
        if (t != .string or !std.mem.eql(u8, t.string, "user")) continue;

        if (obj.get("isSidechain")) |sc| {
            if (sc == .bool and sc.bool) continue;
        }

        if (cwd_opt == null) {
            if (obj.get("cwd")) |cv| if (cv == .string) {
                cwd_opt = try allocator.dupe(u8, cv.string);
            };
        }

        if (started_at_unix == 0) {
            if (obj.get("timestamp")) |tsv| if (tsv == .string) {
                started_at_unix = parseRfc3339(tsv.string) catch |err| blk: {
                    log.debug("failed to parse timestamp: {}", .{err});
                    break :blk 0;
                };
            };
        }

        const message = obj.get("message") orelse continue;
        const msg_obj = switch (message) {
            .object => |o| o,
            else => continue,
        };
        const content = msg_obj.get("content") orelse continue;

        const text = try extractContentText(allocator, content);
        if (text.len == 0) {
            allocator.free(text);
            continue;
        }

        var ts: i64 = started_at_unix;
        if (obj.get("timestamp")) |tsv| if (tsv == .string) {
            ts = parseRfc3339(tsv.string) catch |err| blk: {
                log.debug("failed to parse prompt timestamp: {}", .{err});
                break :blk ts;
            };
        };

        try prompts.append(allocator, .{ .timestamp_unix = ts, .text = text });
    }

    if (prompts.items.len == 0) return session.ParseError.EmptySession;

    const first_text = session.truncateUtf8(prompts.items[0].text, 160);

    const user_prompts = try prompts.toOwnedSlice(allocator);
    errdefer {
        for (user_prompts) |p| allocator.free(p.text);
        allocator.free(user_prompts);
    }

    const stem = std.fs.path.stem(std.fs.path.basename(path));
    const id = try allocator.dupe(u8, stem);
    errdefer allocator.free(id);

    const path_dup = try allocator.dupe(u8, path);
    errdefer allocator.free(path_dup);

    const first = try allocator.dupe(u8, first_text);
    errdefer allocator.free(first);

    return session.Session{
        .agent = .claude,
        .id = id,
        .path = path_dup,
        .cwd = cwd_opt,
        .started_at_unix = started_at_unix,
        .updated_at_unix = @intCast(@divTrunc(stat.mtime, std.time.ns_per_s)),
        .first_prompt = first,
        .user_prompts = user_prompts,
    };
}

/// Frees everything allocated by `parse`.
pub fn freeSession(allocator: std.mem.Allocator, s: session.Session) void {
    allocator.free(s.id);
    allocator.free(s.path);
    if (s.cwd) |c| allocator.free(c);
    allocator.free(s.first_prompt);
    for (s.user_prompts) |p| allocator.free(p.text);
    allocator.free(s.user_prompts);
}

fn extractContentText(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return switch (value) {
        .string => |s| try allocator.dupe(u8, s),
        .array => |arr| blk: {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            errdefer buf.deinit(allocator);
            for (arr.items, 0..) |item, i| {
                if (item != .object) continue;
                const part_type = item.object.get("type") orelse continue;
                if (part_type != .string or !std.mem.eql(u8, part_type.string, "text")) continue;
                const text = item.object.get("text") orelse continue;
                if (text != .string) continue;
                if (i > 0) try buf.append(allocator, '\n');
                try buf.appendSlice(allocator, text.string);
            }
            break :blk try buf.toOwnedSlice(allocator);
        },
        else => try allocator.alloc(u8, 0),
    };
}

/// Parses an ISO-8601 / RFC-3339 timestamp like "2026-05-01T10:00:00.000Z" to unix seconds.
pub fn parseRfc3339(s: []const u8) !i64 {
    if (s.len < 19) return error.InvalidTimestamp;
    const year = try std.fmt.parseInt(i32, s[0..4], 10);
    const month = try std.fmt.parseInt(u8, s[5..7], 10);
    const day = try std.fmt.parseInt(u8, s[8..10], 10);
    const hour = try std.fmt.parseInt(u8, s[11..13], 10);
    const min = try std.fmt.parseInt(u8, s[14..16], 10);
    const sec = try std.fmt.parseInt(u8, s[17..19], 10);

    // Days from civil (Howard Hinnant's algorithm).
    const y = if (month <= 2) year - 1 else year;
    const era: i32 = @divFloor(y, 400);
    const yoe: u32 = @intCast(y - era * 400);
    const doy: u32 = @intCast(@divFloor(@as(i32, 153) * @as(i32, if (month > 2) month - 3 else month + 9) + 2, 5) + day - 1);
    const doe: u32 = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    const days: i64 = @as(i64, era) * 146097 + @as(i64, doe) - 719468;

    return days * 86400 + @as(i64, hour) * 3600 + @as(i64, min) * 60 + @as(i64, sec);
}

test "parse extracts user prompts and skips sidechains" {
    const allocator = std.testing.allocator;
    const sess = try parse(
        allocator,
        "test/fixtures/claude/projects/-Users-alice-dev-foo/11111111-1111-1111-1111-111111111111.jsonl",
    );
    defer freeSession(allocator, sess);

    try std.testing.expectEqual(session.Agent.claude, sess.agent);
    try std.testing.expectEqualStrings("11111111-1111-1111-1111-111111111111", sess.id);
    try std.testing.expectEqualStrings("/Users/alice/dev/foo", sess.cwd.?);
    try std.testing.expectEqualStrings("First prompt", sess.first_prompt);
    try std.testing.expectEqual(@as(usize, 2), sess.user_prompts.len);
    try std.testing.expectEqualStrings("First prompt", sess.user_prompts[0].text);
    try std.testing.expectEqualStrings("Second prompt", sess.user_prompts[1].text);
}

test "parseRfc3339" {
    try std.testing.expectEqual(@as(i64, 0), try parseRfc3339("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(i64, 1735689600), try parseRfc3339("2025-01-01T00:00:00Z"));
}
