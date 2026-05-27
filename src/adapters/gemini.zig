const std = @import("std");
const session = @import("../session.zig");
const claude = @import("claude.zig");

const log = std.log.scoped(.adapter_gemini);

pub const FileRef = claude.FileRef;

pub fn discover(allocator: std.mem.Allocator, root: []const u8) ![]FileRef {
    return claude.discover(allocator, root);
}

pub const ProjectsMap = std.StringHashMap([]const u8);

pub fn loadProjectsMap(allocator: std.mem.Allocator, path: []const u8) !ProjectsMap {
    var map = ProjectsMap.init(allocator);
    errdefer freeProjectsMap(allocator, &map);

    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return map,
        else => return err,
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 4 * 1024 * 1024);
    defer allocator.free(contents);

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        contents,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    if (parsed.value != .object) return map;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        const k = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(k);
        const v = try allocator.dupe(u8, entry.value_ptr.*.string);
        try map.put(k, v);
    }
    return map;
}

pub fn freeProjectsMap(allocator: std.mem.Allocator, map: *ProjectsMap) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

pub fn parse(allocator: std.mem.Allocator, path: []const u8, projects: ?*const ProjectsMap) !session.Session {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const contents = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(contents);

    var project_hash: ?[]u8 = null;
    errdefer if (project_hash) |h| allocator.free(h);
    var started_at_unix: i64 = 0;

    var prompts: std.ArrayListUnmanaged(session.UserPrompt) = .empty;
    errdefer {
        for (prompts.items) |p| allocator.free(p.text);
        prompts.deinit(allocator);
    }

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

        if (obj.get("projectHash")) |v| if (v == .string and project_hash == null) {
            project_hash = try allocator.dupe(u8, v.string);
        };
        if (obj.get("startTime")) |v| if (v == .string and started_at_unix == 0) {
            started_at_unix = parseRfc3339(v.string) catch |err| blk: {
                log.debug("failed to parse startTime: {}", .{err});
                break :blk 0;
            };
        };

        const t = obj.get("type") orelse continue;
        if (t != .string or !std.mem.eql(u8, t.string, "user")) continue;
        const content = obj.get("content") orelse continue;
        if (content != .array) continue;

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);
        for (content.array.items, 0..) |item, i| {
            if (item != .object) continue;
            const text = item.object.get("text") orelse continue;
            if (text != .string) continue;
            if (i > 0) try buf.append(allocator, '\n');
            try buf.appendSlice(allocator, text.string);
        }
        if (buf.items.len == 0) {
            buf.deinit(allocator);
            continue;
        }

        var ts: i64 = started_at_unix;
        if (obj.get("timestamp")) |v| if (v == .string) {
            ts = parseRfc3339(v.string) catch |err| blk: {
                log.debug("failed to parse prompt timestamp: {}", .{err});
                break :blk ts;
            };
        };
        try prompts.append(allocator, .{
            .timestamp_unix = ts,
            .text = try buf.toOwnedSlice(allocator),
        });
    }

    if (prompts.items.len == 0) return session.ParseError.EmptySession;

    var cwd_opt: ?[]u8 = null;
    if (project_hash) |h| {
        defer allocator.free(h);
        project_hash = null;
        if (projects) |p| if (p.get(h)) |dir| {
            cwd_opt = try allocator.dupe(u8, dir);
        };
    }

    const stem = std.fs.path.stem(std.fs.path.basename(path));
    const id = try allocator.dupe(u8, stem);
    errdefer allocator.free(id);
    const path_dup = try allocator.dupe(u8, path);
    errdefer allocator.free(path_dup);
    const first = try allocator.dupe(u8, session.truncateUtf8(prompts.items[0].text, 160));
    errdefer allocator.free(first);

    return session.Session{
        .agent = .gemini,
        .id = id,
        .path = path_dup,
        .cwd = cwd_opt,
        .started_at_unix = started_at_unix,
        .updated_at_unix = @intCast(@divTrunc(stat.mtime, std.time.ns_per_s)),
        .first_prompt = first,
        .user_prompts = try prompts.toOwnedSlice(allocator),
    };
}

pub fn freeSession(allocator: std.mem.Allocator, s: session.Session) void {
    claude.freeSession(allocator, s);
}

const parseRfc3339 = @import("claude.zig").parseRfc3339;

test "loadProjectsMap reads fixture" {
    const allocator = std.testing.allocator;
    var map = try loadProjectsMap(allocator, "test/fixtures/gemini/projects.json");
    defer freeProjectsMap(allocator, &map);
    try std.testing.expectEqualStrings(
        "/Users/alice/dev/gemini-demo",
        map.get("abcd1234abcd").?,
    );
}

test "loadProjectsMap returns empty when file is missing" {
    const allocator = std.testing.allocator;
    var map = try loadProjectsMap(allocator, "test/fixtures/gemini/does-not-exist.json");
    defer freeProjectsMap(allocator, &map);
    try std.testing.expectEqual(@as(u32, 0), map.count());
}

test "parse resolves cwd via projects map and extracts prompts" {
    const allocator = std.testing.allocator;
    var projects = try loadProjectsMap(allocator, "test/fixtures/gemini/projects.json");
    defer freeProjectsMap(allocator, &projects);

    const sess = try parse(
        allocator,
        "test/fixtures/gemini/tmp/abcd1234abcd/chats/session-2026-05-04T05-37-77677bcc.jsonl",
        &projects,
    );
    defer freeSession(allocator, sess);

    try std.testing.expectEqual(session.Agent.gemini, sess.agent);
    try std.testing.expectEqualStrings("/Users/alice/dev/gemini-demo", sess.cwd.?);
    try std.testing.expectEqual(@as(usize, 2), sess.user_prompts.len);
    try std.testing.expectEqualStrings("Hello from gemini", sess.user_prompts[0].text);
}

test "parse leaves cwd null when project hash is unknown" {
    const allocator = std.testing.allocator;
    var projects = ProjectsMap.init(allocator);
    defer projects.deinit();

    const sess = try parse(
        allocator,
        "test/fixtures/gemini/tmp/abcd1234abcd/chats/session-2026-05-04T05-37-77677bcc.jsonl",
        &projects,
    );
    defer freeSession(allocator, sess);

    try std.testing.expect(sess.cwd == null);
}
