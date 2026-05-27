const std = @import("std");

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

test "discover finds fixture sessions" {
    const allocator = std.testing.allocator;
    const refs = try discover(allocator, "test/fixtures/claude/projects");
    defer {
        for (refs) |r| allocator.free(r.path);
        allocator.free(refs);
    }
    try std.testing.expectEqual(@as(usize, 1), refs.len);
    try std.testing.expect(std.mem.endsWith(u8, refs[0].path, ".jsonl"));
    try std.testing.expect(refs[0].mtime_unix > 0);
}
