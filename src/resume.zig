const std = @import("std");
const session = @import("session.zig");

const log = std.log.scoped(.resume_);

pub const Spawner = struct {
    pub const Vtable = struct {
        spawn: *const fn (ctx: *anyopaque, argv: []const []const u8, cwd: ?[]const u8) anyerror!void,
    };
    ctx: *anyopaque,
    vtable: *const Vtable,

    pub fn spawn(self: Spawner, argv: []const []const u8, cwd: ?[]const u8) !void {
        return self.vtable.spawn(self.ctx, argv, cwd);
    }
};

pub fn buildArgv(allocator: std.mem.Allocator, agent: session.Agent, id_or_path: []const u8) ![][]const u8 {
    var argv = try allocator.alloc([]const u8, 3);
    errdefer allocator.free(argv);

    switch (agent) {
        .claude => {
            argv[0] = try allocator.dupe(u8, "claude");
            argv[1] = try allocator.dupe(u8, "--resume");
            argv[2] = try allocator.dupe(u8, id_or_path);
        },
        .codex => {
            argv[0] = try allocator.dupe(u8, "codex");
            argv[1] = try allocator.dupe(u8, "resume");
            argv[2] = try allocator.dupe(u8, id_or_path);
        },
        .gemini => {
            argv[0] = try allocator.dupe(u8, "gemini");
            argv[1] = try allocator.dupe(u8, "--session-file");
            argv[2] = try allocator.dupe(u8, id_or_path);
        },
    }
    return argv;
}

pub fn freeArgv(allocator: std.mem.Allocator, argv: [][]const u8) void {
    for (argv) |a| allocator.free(a);
    allocator.free(argv);
}

pub fn resumeSession(
    spawner: Spawner,
    agent: session.Agent,
    id_or_path: []const u8,
    cwd: ?[]const u8,
    allocator: std.mem.Allocator,
) !void {
    const argv = try buildArgv(allocator, agent, id_or_path);
    defer freeArgv(allocator, argv);
    try spawner.spawn(argv, cwd);
}

fn execSpawnImpl(_: *anyopaque, argv: []const []const u8, cwd: ?[]const u8) anyerror!void {
    if (cwd) |c| {
        std.process.changeCurDir(c) catch |err| {
            log.warn("chdir({s}) failed: {s}", .{ c, @errorName(err) });
        };
    }
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    return std.process.execv(arena.allocator(), argv);
}

const exec_vtable: Spawner.Vtable = .{ .spawn = execSpawnImpl };

pub const ExecSpawner = struct {
    var sentinel: u8 = 0;

    pub fn spawner() Spawner {
        return .{ .ctx = &sentinel, .vtable = &exec_vtable };
    }
};

test "resume builds the right argv per agent" {
    const allocator = std.testing.allocator;

    const RecordedSpawn = struct {
        argv: [][]u8,
        cwd: ?[]u8,
    };

    const TestSpawner = struct {
        allocator: std.mem.Allocator,
        last: ?RecordedSpawn = null,

        fn spawnImpl(ctx: *anyopaque, argv: []const []const u8, cwd: ?[]const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.last) |old| {
                for (old.argv) |a| self.allocator.free(a);
                self.allocator.free(old.argv);
                if (old.cwd) |c| self.allocator.free(c);
            }
            const owned = try self.allocator.alloc([]u8, argv.len);
            for (argv, 0..) |a, i| owned[i] = try self.allocator.dupe(u8, a);
            self.last = .{
                .argv = owned,
                .cwd = if (cwd) |c| try self.allocator.dupe(u8, c) else null,
            };
        }

        const vtable: Spawner.Vtable = .{ .spawn = spawnImpl };

        fn spawner(self: *@This()) Spawner {
            return .{ .ctx = self, .vtable = &@This().vtable };
        }

        fn deinit(self: *@This()) void {
            if (self.last) |old| {
                for (old.argv) |a| self.allocator.free(a);
                self.allocator.free(old.argv);
                if (old.cwd) |c| self.allocator.free(c);
            }
        }
    };

    var ts = TestSpawner{ .allocator = allocator };
    defer ts.deinit();
    const sp = ts.spawner();

    try resumeSession(sp, .claude, "uuid-1", "/tmp", allocator);
    try std.testing.expectEqualStrings("claude", ts.last.?.argv[0]);
    try std.testing.expectEqualStrings("--resume", ts.last.?.argv[1]);
    try std.testing.expectEqualStrings("uuid-1", ts.last.?.argv[2]);
    try std.testing.expectEqualStrings("/tmp", ts.last.?.cwd.?);

    try resumeSession(sp, .codex, "uuid-2", null, allocator);
    try std.testing.expectEqualStrings("codex", ts.last.?.argv[0]);
    try std.testing.expectEqualStrings("resume", ts.last.?.argv[1]);
    try std.testing.expectEqualStrings("uuid-2", ts.last.?.argv[2]);
    try std.testing.expect(ts.last.?.cwd == null);

    try resumeSession(sp, .gemini, "/path/to/session.jsonl", "/work", allocator);
    try std.testing.expectEqualStrings("gemini", ts.last.?.argv[0]);
    try std.testing.expectEqualStrings("--session-file", ts.last.?.argv[1]);
    try std.testing.expectEqualStrings("/path/to/session.jsonl", ts.last.?.argv[2]);
}
