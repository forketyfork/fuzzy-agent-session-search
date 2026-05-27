const std = @import("std");
const session = @import("../session.zig");
const claude = @import("claude.zig");

const log = std.log.scoped(.adapter_codex);

pub const FileRef = claude.FileRef;

pub fn discover(allocator: std.mem.Allocator, root: []const u8) ![]FileRef {
    return claude.discover(allocator, root);
}

pub fn parse(allocator: std.mem.Allocator, path: []const u8) !session.Session {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const contents = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(contents);

    var id_opt: ?[]u8 = null;
    var cwd_opt: ?[]u8 = null;
    var started_at_unix: i64 = 0;
    errdefer if (id_opt) |s| allocator.free(s);
    errdefer if (cwd_opt) |s| allocator.free(s);

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

        const top_type = obj.get("type") orelse continue;
        if (top_type != .string) continue;
        const payload = obj.get("payload") orelse continue;
        if (payload != .object) continue;

        if (std.mem.eql(u8, top_type.string, "session_meta")) {
            if (payload.object.get("id")) |v| if (v == .string and id_opt == null) {
                id_opt = try allocator.dupe(u8, v.string);
            };
            if (payload.object.get("cwd")) |v| if (v == .string and cwd_opt == null) {
                cwd_opt = try allocator.dupe(u8, v.string);
            };
            if (payload.object.get("timestamp")) |v| if (v == .string and started_at_unix == 0) {
                started_at_unix = parseRfc3339(v.string) catch |err| blk: {
                    log.debug("failed to parse session_meta timestamp: {}", .{err});
                    break :blk 0;
                };
            };
            continue;
        }

        if (!std.mem.eql(u8, top_type.string, "response_item")) continue;
        const inner_type = payload.object.get("type") orelse continue;
        if (inner_type != .string or !std.mem.eql(u8, inner_type.string, "message")) continue;
        const role = payload.object.get("role") orelse continue;
        if (role != .string or !std.mem.eql(u8, role.string, "user")) continue;
        const content = payload.object.get("content") orelse continue;
        const text = try extractInputText(allocator, content);
        if (text.len == 0 or isWrapperEnvelope(text)) {
            allocator.free(text);
            continue;
        }

        var ts: i64 = started_at_unix;
        if (obj.get("timestamp")) |v| if (v == .string) {
            ts = parseRfc3339(v.string) catch |err| blk: {
                log.debug("failed to parse prompt timestamp: {}", .{err});
                break :blk ts;
            };
        };
        try prompts.append(allocator, .{ .timestamp_unix = ts, .text = text });
    }

    if (prompts.items.len == 0) return session.ParseError.EmptySession;
    const id = id_opt orelse return session.ParseError.MissingField;

    const path_dup = try allocator.dupe(u8, path);
    errdefer allocator.free(path_dup);
    const first = try allocator.dupe(u8, session.truncateUtf8(prompts.items[0].text, 160));
    errdefer allocator.free(first);

    return session.Session{
        .agent = .codex,
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

fn extractInputText(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    if (value != .array) return try allocator.alloc(u8, 0);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (value.array.items, 0..) |item, i| {
        if (item != .object) continue;
        const part_type = item.object.get("type") orelse continue;
        if (part_type != .string or !std.mem.eql(u8, part_type.string, "input_text")) continue;
        const text = item.object.get("text") orelse continue;
        if (text != .string) continue;
        if (i > 0) try buf.append(allocator, '\n');
        try buf.appendSlice(allocator, text.string);
    }
    return try buf.toOwnedSlice(allocator);
}

const parseRfc3339 = @import("claude.zig").parseRfc3339;

/// Codex injects synthetic user messages wrapping its preamble:
/// - `<user_instructions>…</user_instructions>` / `<environment_context>…</environment_context>`
///   blocks for the global instructions and env context;
/// - a per-project AGENTS.md dump prefixed with `# AGENTS.md instructions for <path>`,
///   one per project tree that has an AGENTS.md.
/// None are user-typed, so skip them when building the search corpus and preview.
fn isWrapperEnvelope(text: []const u8) bool {
    const stripped = std.mem.trim(u8, text, " \t\r\n");
    return std.mem.startsWith(u8, stripped, "<user_instructions>") or
        std.mem.startsWith(u8, stripped, "<environment_context>") or
        std.mem.startsWith(u8, stripped, "# AGENTS.md instructions for ");
}

test "isWrapperEnvelope flags codex preamble messages" {
    try std.testing.expect(isWrapperEnvelope("<user_instructions>\nrules\n</user_instructions>"));
    try std.testing.expect(isWrapperEnvelope("  \n<environment_context>x</environment_context>"));
    try std.testing.expect(isWrapperEnvelope("# AGENTS.md instructions for /Users/alice/dev/foo\n\n<INSTRUCTIONS>…"));
    try std.testing.expect(!isWrapperEnvelope("Help me refactor this parser"));
    try std.testing.expect(!isWrapperEnvelope("<other_tag>nope</other_tag>"));
    try std.testing.expect(!isWrapperEnvelope("# Heading that happens to start with hash"));
}

test "discover walks codex sessions tree" {
    const allocator = std.testing.allocator;
    const refs = try discover(allocator, "test/fixtures/codex/sessions");
    defer {
        for (refs) |r| allocator.free(r.path);
        allocator.free(refs);
    }
    try std.testing.expectEqual(@as(usize, 1), refs.len);
}

test "parse extracts cwd, id, and user prompts from session_meta + response_items" {
    const allocator = std.testing.allocator;
    const sess = try parse(
        allocator,
        "test/fixtures/codex/sessions/2026/05/26/rollout-2026-05-26T06-50-13-019e629e-78de-7272-875b-c4986c5eda0b.jsonl",
    );
    defer freeSession(allocator, sess);

    try std.testing.expectEqual(session.Agent.codex, sess.agent);
    try std.testing.expectEqualStrings("019e629e-78de-7272-875b-c4986c5eda0b", sess.id);
    try std.testing.expectEqualStrings("/Users/alice/dev/codex-demo", sess.cwd.?);
    try std.testing.expectEqual(@as(usize, 2), sess.user_prompts.len);
    try std.testing.expectEqualStrings("Help me refactor this parser", sess.user_prompts[0].text);
}
