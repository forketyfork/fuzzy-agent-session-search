const std = @import("std");
const sqlite = @import("sqlite.zig");
const session = @import("session.zig");
const claude = @import("adapters/claude.zig");
const codex = @import("adapters/codex.zig");
const gemini = @import("adapters/gemini.zig");
const index_mod = @import("index.zig");
const picker = @import("picker.zig");
const resume_mod = @import("resume.zig");
const refresh_mod = @import("refresh.zig");

pub fn main() !void {
    var buf: [128]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "fzag v0.1.0 (sqlite {s})\n", .{sqlite.libVersion()});
    try std.fs.File.stdout().writeAll(msg);
}

test {
    _ = session;
    _ = claude;
    _ = codex;
    _ = gemini;
    _ = index_mod;
    _ = picker;
    _ = resume_mod;
    _ = refresh_mod;
    std.testing.refAllDecls(@This());
}
