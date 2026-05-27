const std = @import("std");
const sqlite = @import("sqlite.zig");

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
