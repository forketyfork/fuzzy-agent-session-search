const std = @import("std");

pub const Agent = enum {
    claude,
    codex,
    gemini,

    pub fn fromString(s: []const u8) ?Agent {
        if (std.mem.eql(u8, s, "claude")) return .claude;
        if (std.mem.eql(u8, s, "codex")) return .codex;
        if (std.mem.eql(u8, s, "gemini")) return .gemini;
        return null;
    }

    pub fn toString(self: Agent) []const u8 {
        return switch (self) {
            .claude => "claude",
            .codex => "codex",
            .gemini => "gemini",
        };
    }
};

pub const UserPrompt = struct {
    timestamp_unix: i64,
    text: []const u8,
};

pub const Session = struct {
    agent: Agent,
    id: []const u8,
    path: []const u8,
    cwd: ?[]const u8,
    started_at_unix: i64,
    updated_at_unix: i64,
    first_prompt: []const u8,
    user_prompts: []const UserPrompt,
};

pub const ParseError = error{
    InvalidJson,
    MissingField,
    UnknownAgent,
    EmptySession,
};

/// Truncate `text` to at most `max_bytes`, snapping back to a UTF-8 boundary.
/// Returns a slice of `text` (no allocation).
pub fn truncateUtf8(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    var end: usize = max_bytes;
    while (end > 0 and (text[end] & 0b1100_0000) == 0b1000_0000) : (end -= 1) {}
    return text[0..end];
}

test "Agent.fromString / toString roundtrip" {
    inline for (.{ Agent.claude, Agent.codex, Agent.gemini }) |a| {
        try std.testing.expectEqual(a, Agent.fromString(a.toString()).?);
    }
    try std.testing.expect(Agent.fromString("rust") == null);
}

test "truncateUtf8 snaps to boundary" {
    try std.testing.expectEqualStrings("hello", truncateUtf8("hello", 10));
    try std.testing.expectEqualStrings("hel", truncateUtf8("hello", 3));
    const multibyte = "héllo"; // é is two bytes (0xC3 0xA9)
    try std.testing.expectEqualStrings("h", truncateUtf8(multibyte, 2));
}
