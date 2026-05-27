const std = @import("std");
const sqlite = @import("sqlite.zig");
const session = @import("session.zig");

const log = std.log.scoped(.index);
const c = sqlite.c;

pub const schema_version: i64 = 1;

pub const SqlError = error{
    OpenFailed,
    PrepareFailed,
    StepFailed,
    BindFailed,
    NoRow,
};

pub const Index = struct {
    db: *c.sqlite3,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: [:0]const u8) !Index {
        var db_ptr: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path.ptr, &db_ptr);
        if (rc != c.SQLITE_OK or db_ptr == null) {
            if (db_ptr) |p| _ = c.sqlite3_close(p);
            return SqlError.OpenFailed;
        }
        var self = Index{ .db = db_ptr.?, .allocator = allocator };
        errdefer _ = c.sqlite3_close(self.db);

        try self.exec("PRAGMA journal_mode=WAL");
        try self.exec("PRAGMA synchronous=NORMAL");
        try self.exec("PRAGMA foreign_keys=ON");
        try self.exec("PRAGMA temp_store=MEMORY");

        try self.exec(
            \\CREATE TABLE IF NOT EXISTS meta (
            \\  key TEXT PRIMARY KEY,
            \\  value TEXT NOT NULL
            \\);
        );
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS sessions (
            \\  path TEXT PRIMARY KEY,
            \\  agent TEXT NOT NULL,
            \\  id TEXT NOT NULL,
            \\  cwd TEXT,
            \\  started_at INTEGER NOT NULL,
            \\  updated_at INTEGER NOT NULL,
            \\  first_prompt TEXT NOT NULL,
            \\  search_corpus TEXT NOT NULL
            \\);
        );
        try self.exec("CREATE INDEX IF NOT EXISTS sessions_agent_id ON sessions(agent, id);");
        try self.exec("CREATE INDEX IF NOT EXISTS sessions_updated_at ON sessions(updated_at DESC);");
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS user_prompts (
            \\  session_path TEXT NOT NULL,
            \\  idx INTEGER NOT NULL,
            \\  ts INTEGER NOT NULL,
            \\  text TEXT NOT NULL,
            \\  PRIMARY KEY(session_path, idx),
            \\  FOREIGN KEY(session_path) REFERENCES sessions(path) ON DELETE CASCADE
            \\);
        );

        try self.exec("INSERT OR IGNORE INTO meta(key, value) VALUES('schema_version', '1')");
        return self;
    }

    pub fn close(self: *Index) void {
        _ = c.sqlite3_close(self.db);
    }

    pub fn exec(self: *Index, sql: []const u8) !void {
        const sql_z: [:0]u8 = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql_z.ptr, null, null, &errmsg);
        if (rc != c.SQLITE_OK) {
            if (errmsg != null) {
                log.err("sqlite exec failed: {s}", .{errmsg});
                c.sqlite3_free(errmsg);
            }
            return SqlError.StepFailed;
        }
    }

    pub fn schemaVersion(self: *Index) !i64 {
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "SELECT value FROM meta WHERE key='schema_version'";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return SqlError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return SqlError.NoRow;
        const txt = c.sqlite3_column_text(stmt, 0);
        const slice = std.mem.span(@as([*:0]const u8, @ptrCast(txt)));
        return std.fmt.parseInt(i64, slice, 10);
    }

    pub fn upsertSession(self: *Index, s: session.Session) !void {
        try self.exec("BEGIN");
        errdefer self.exec("ROLLBACK") catch |err| {
            log.debug("rollback failed: {}", .{err});
        };

        {
            const sql = "DELETE FROM user_prompts WHERE session_path=?";
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return SqlError.PrepareFailed;
            defer _ = c.sqlite3_finalize(stmt);
            _ = c.sqlite3_bind_text(stmt, 1, s.path.ptr, @intCast(s.path.len), @ptrFromInt(0));
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return SqlError.StepFailed;
        }

        var corpus: std.ArrayListUnmanaged(u8) = .empty;
        defer corpus.deinit(self.allocator);
        for (s.user_prompts, 0..) |p, i| {
            if (i > 0) try corpus.append(self.allocator, ' ');
            for (p.text) |ch| {
                try corpus.append(self.allocator, if (ch == '\n' or ch == '\r') ' ' else ch);
            }
        }

        {
            const sql =
                \\INSERT OR REPLACE INTO sessions
                \\  (path, agent, id, cwd, started_at, updated_at, first_prompt, search_corpus)
                \\VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            ;
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return SqlError.PrepareFailed;
            defer _ = c.sqlite3_finalize(stmt);

            _ = c.sqlite3_bind_text(stmt, 1, s.path.ptr, @intCast(s.path.len), @ptrFromInt(0));
            const agent_str = s.agent.toString();
            _ = c.sqlite3_bind_text(stmt, 2, agent_str.ptr, @intCast(agent_str.len), @ptrFromInt(0));
            _ = c.sqlite3_bind_text(stmt, 3, s.id.ptr, @intCast(s.id.len), @ptrFromInt(0));
            if (s.cwd) |cw| {
                _ = c.sqlite3_bind_text(stmt, 4, cw.ptr, @intCast(cw.len), @ptrFromInt(0));
            } else {
                _ = c.sqlite3_bind_null(stmt, 4);
            }
            _ = c.sqlite3_bind_int64(stmt, 5, s.started_at_unix);
            _ = c.sqlite3_bind_int64(stmt, 6, s.updated_at_unix);
            _ = c.sqlite3_bind_text(stmt, 7, s.first_prompt.ptr, @intCast(s.first_prompt.len), @ptrFromInt(0));
            _ = c.sqlite3_bind_text(stmt, 8, corpus.items.ptr, @intCast(corpus.items.len), @ptrFromInt(0));
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return SqlError.StepFailed;
        }

        {
            const sql = "INSERT INTO user_prompts(session_path, idx, ts, text) VALUES (?, ?, ?, ?)";
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return SqlError.PrepareFailed;
            defer _ = c.sqlite3_finalize(stmt);

            for (s.user_prompts, 0..) |p, i| {
                _ = c.sqlite3_reset(stmt);
                _ = c.sqlite3_bind_text(stmt, 1, s.path.ptr, @intCast(s.path.len), @ptrFromInt(0));
                _ = c.sqlite3_bind_int64(stmt, 2, @intCast(i));
                _ = c.sqlite3_bind_int64(stmt, 3, p.timestamp_unix);
                _ = c.sqlite3_bind_text(stmt, 4, p.text.ptr, @intCast(p.text.len), @ptrFromInt(0));
                if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return SqlError.StepFailed;
            }
        }

        try self.exec("COMMIT");
    }

    pub fn getMtime(self: *Index, path: []const u8) !?i64 {
        const sql = "SELECT updated_at FROM sessions WHERE path=?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return SqlError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, path.ptr, @intCast(path.len), @ptrFromInt(0));
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return SqlError.StepFailed;
        return c.sqlite3_column_int64(stmt, 0);
    }

    pub fn pruneMissing(self: *Index, keep_paths: []const []const u8) !void {
        try self.exec("CREATE TEMP TABLE IF NOT EXISTS _keep(path TEXT PRIMARY KEY)");
        try self.exec("DELETE FROM _keep");

        const insert_sql = "INSERT OR IGNORE INTO _keep(path) VALUES (?)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, insert_sql, -1, &stmt, null) != c.SQLITE_OK) return SqlError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        for (keep_paths) |p| {
            _ = c.sqlite3_reset(stmt);
            _ = c.sqlite3_bind_text(stmt, 1, p.ptr, @intCast(p.len), @ptrFromInt(0));
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return SqlError.StepFailed;
        }

        try self.exec("DELETE FROM sessions WHERE path NOT IN (SELECT path FROM _keep)");
    }

    pub fn lookupCwd(self: *Index, allocator: std.mem.Allocator, agent: session.Agent, id: []const u8) !?[]u8 {
        const sql = "SELECT cwd FROM sessions WHERE agent=? AND id=? LIMIT 1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return SqlError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        const a = agent.toString();
        _ = c.sqlite3_bind_text(stmt, 1, a.ptr, @intCast(a.len), @ptrFromInt(0));
        _ = c.sqlite3_bind_text(stmt, 2, id.ptr, @intCast(id.len), @ptrFromInt(0));
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return SqlError.StepFailed;
        if (c.sqlite3_column_type(stmt, 0) == c.SQLITE_NULL) return null;
        const ptr = c.sqlite3_column_text(stmt, 0);
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        return try allocator.dupe(u8, @as([*]const u8, @ptrCast(ptr))[0..len]);
    }
};

test "open creates the schema and reports version 1" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const db_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/index.sqlite", .{root});
    defer std.testing.allocator.free(db_path);
    const db_path_z: [:0]u8 = try std.testing.allocator.dupeZ(u8, db_path);
    defer std.testing.allocator.free(db_path_z);

    var idx = try Index.open(std.testing.allocator, db_path_z);
    defer idx.close();

    try std.testing.expectEqual(@as(i64, 1), try idx.schemaVersion());
}

test "upsertSession stores a session and its prompts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const db_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/i.sqlite", .{root});
    defer std.testing.allocator.free(db_path);
    const db_path_z: [:0]u8 = try std.testing.allocator.dupeZ(u8, db_path);
    defer std.testing.allocator.free(db_path_z);

    var idx = try Index.open(std.testing.allocator, db_path_z);
    defer idx.close();

    const prompts = [_]session.UserPrompt{
        .{ .timestamp_unix = 100, .text = "hi" },
        .{ .timestamp_unix = 200, .text = "there" },
    };
    const sess = session.Session{
        .agent = .claude,
        .id = "abc",
        .path = "/tmp/x.jsonl",
        .cwd = "/tmp",
        .started_at_unix = 100,
        .updated_at_unix = 1000,
        .first_prompt = "hi",
        .user_prompts = &prompts,
    };
    try idx.upsertSession(sess);

    const looked_up = try idx.lookupCwd(std.testing.allocator, .claude, "abc");
    defer if (looked_up) |s| std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("/tmp", looked_up.?);
}

test "refresh deletes vanished sessions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const db_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/i.sqlite", .{root});
    defer std.testing.allocator.free(db_path);
    const db_path_z: [:0]u8 = try std.testing.allocator.dupeZ(u8, db_path);
    defer std.testing.allocator.free(db_path_z);

    var idx = try Index.open(std.testing.allocator, db_path_z);
    defer idx.close();

    try idx.upsertSession(.{
        .agent = .claude,
        .id = "stays",
        .path = "/a",
        .cwd = null,
        .started_at_unix = 1,
        .updated_at_unix = 1,
        .first_prompt = "p",
        .user_prompts = &.{},
    });
    try idx.upsertSession(.{
        .agent = .claude,
        .id = "gone",
        .path = "/b",
        .cwd = null,
        .started_at_unix = 1,
        .updated_at_unix = 1,
        .first_prompt = "p",
        .user_prompts = &.{},
    });

    const kept = [_][]const u8{"/a"};
    try idx.pruneMissing(&kept);

    try std.testing.expect((try idx.getMtime("/a")) != null);
    try std.testing.expect((try idx.getMtime("/b")) == null);
}
