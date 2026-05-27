const std = @import("std");
const sqlite = @import("sqlite.zig");
const session = @import("session.zig");

pub fn main() !void {
    var buf: [128]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "fzag v0.1.0 (sqlite {s})\n", .{sqlite.libVersion()});
    try std.fs.File.stdout().writeAll(msg);
}

test {
    _ = session;
    std.testing.refAllDecls(@This());
}
