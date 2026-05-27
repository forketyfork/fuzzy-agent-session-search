const std = @import("std");

pub fn main() !void {
    try std.fs.File.stdout().writeAll("fzag v0.1.0\n");
}

test "smoke" {
    try std.testing.expect(true);
}
