const std = @import("std");

pub const c = @import("c_sqlite");

pub fn libVersion() []const u8 {
    return std.mem.span(c.sqlite3_libversion());
}

test "sqlite linked" {
    const v = libVersion();
    try std.testing.expect(v.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, v, "3."));
}
