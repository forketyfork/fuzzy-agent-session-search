const std = @import("std");

pub fn main() !void {
    try std.fs.File.stdout().writeAll("fzag v0.1.0\n");
}

test "version string is non-empty" {
    const version = "fzag v0.1.0";
    try std.testing.expect(version.len > 0);
}
