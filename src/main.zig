const std = @import("std");
const sqlite = @import("sqlite.zig");

pub fn main() !void {
    var buf: [128]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "fzag v0.1.0 (sqlite {s})\n", .{sqlite.libVersion()});
    try std.fs.File.stdout().writeAll(msg);
}

test {
    std.testing.refAllDecls(@This());
}

test "version string is non-empty" {
    const version = "fzag v0.1.0";
    try std.testing.expect(version.len > 0);
}
