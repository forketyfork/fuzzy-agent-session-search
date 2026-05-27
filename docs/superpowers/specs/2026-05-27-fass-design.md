# fzag — Unified Agentic-Session Picker

**Date:** 2026-05-27
**Status:** Design

## 1. Purpose

A single CLI that fuzzy-searches across Claude Code, Codex, and Gemini CLI session histories and resumes the chosen session. The user starts typing, fzf narrows the list across all three agents, selection execs the right resume command in the session's original working directory.

## 2. Goals and Non-Goals

**Goals**

- One picker for all three agents; no per-agent invocation needed.
- Fuzzy match against every user prompt in every session (the user remembers what *they* typed, not what the model said).
- Sub-second startup once warm, via a persistent index that refreshes incrementally on file mtime.
- Resume drops the user into the session's original cwd before exec'ing the agent.

**Non-goals**

- Editing, deleting, or exporting sessions.
- Cross-agent semantics: a Claude session resumed in Codex makes no sense; each session belongs to its origin agent.
- Full-text search of assistant messages or tool output (out of scope for v1; index would balloon).
- Cloud sync, multi-machine indexing.

## 3. Toolchain

- **Language:** Zig 0.15.2 (matches zwanzig and the rest of the user's Zig projects).
- **Build:** `zig build` / `zig build test` / `zig build run -- <args>`. No external runtime; the resulting binary is statically linked.
- **SQLite:** vendor the official `sqlite3.c` amalgamation under `vendor/sqlite/` and link it via `@cImport`. Avoids tracking a third-party Zig binding against the Zig release train; the C-interop pattern is well-trodden (see the zig-best-practices C-INTEROP guide).
- **Linter:** [zwanzig](https://github.com/forketyfork/zwanzig) wired into the build from the first commit. Locally via `just lint` (mirrors zwanzig's own justfile); in CI as a SARIF upload to GitHub Code Scanning. `zig fmt --check src/` runs in the same step.
- **Style:** follow the zig-best-practices skill: explicit error sets, tagged unions for mutually-exclusive state, `comptime T: type` over `anytype`, allocators passed explicitly, `std.log.scoped` per module, `std.testing.allocator` in tests.

## 4. Architecture

Single Zig binary. Files are cohesive (per the skill's "larger cohesive files are idiomatic" note), one file per concern:

```
build.zig
build.zig.zon
src/
  main.zig            entry, flag parsing, subcommand dispatch
  session.zig         Session struct, Agent enum, shared helpers
  adapters/
    claude.zig        discover + parse Claude JSONL
    codex.zig         discover + parse Codex JSONL
    gemini.zig        discover + parse Gemini JSONL
  index.zig           SQLite schema, incremental refresh, lookups
  picker.zig          spawn fzf/sk, pipe stdin, read stdout
  resume.zig          chdir + execv into the agent CLI
vendor/sqlite/
  sqlite3.c           amalgamation, committed
  sqlite3.h
test/
  fixtures/           sample JSONL files per agent
  ...
```

Each adapter exposes the same two-function contract: `discover(allocator) -> []FileRef` and `parse(allocator, path) !Session`. Nothing above `adapters/` knows the per-agent JSONL shape.

## 5. Data Model

`Agent` is a closed enum; making it a string would invite typos and defeat exhaustive `switch`.

```zig
pub const Agent = enum { claude, codex, gemini };

pub const UserPrompt = struct {
    timestamp_unix: i64,
    text: []const u8, // owned by the session's arena
};

pub const Session = struct {
    agent: Agent,
    /// UUID for claude/codex; file path stem for gemini (which has no
    /// session-id CLI argument).
    id: []const u8,
    path: []const u8,          // absolute path to the JSONL file
    cwd: ?[]const u8,          // null if unknown (Gemini hash unresolved)
    started_at_unix: i64,
    updated_at_unix: i64,      // file mtime, drives incremental refresh
    first_prompt: []const u8,  // truncated to 160 bytes (UTF-8 boundary-safe)
    user_prompts: []UserPrompt, // every user message, for search + preview
};

pub const ParseError = error{
    InvalidJson,
    MissingField,
    UnknownAgent,
    EmptySession,
};
```

`user_prompts[*].text` joined with spaces is the search corpus handed to fzf; the same slice is what the preview subcommand prints. All string slices in a `Session` are owned by an arena tied to that session's parse, freed wholesale when the session is no longer needed.

## 6. Adapters

### 6.1 Claude

- **Discovery glob:** `~/.claude/projects/*/*.jsonl`
- **ID:** filename stem (the UUID).
- **Cwd:** read the `cwd` field from any line that has it (typically every `user` message line). Directory name is the encoded cwd but the per-line field is authoritative.
- **User prompts:** lines with `type == "user"` and `isSidechain != true`. `message.content` is either a string or an array of `{type:"text", text:"..."}` parts; concatenate the text parts.
- **Started at:** earliest `timestamp` field encountered.
- **Resume command:** `claude --resume <ID>`

### 6.2 Codex

- **Discovery glob:** `~/.codex/sessions/*/*/*/rollout-*.jsonl`
- **ID:** from the first line's `payload.id` (the UUID), which also appears in the filename.
- **Cwd:** first line's `payload.cwd`.
- **Started at:** first line's `payload.timestamp`.
- **User prompts:** lines representing user input. The exact shape (likely `type == "response_item"` with `payload.role == "user"`) must be confirmed during implementation by reading a real file; the adapter isolates this so changes do not ripple.
- **Started at field:** parse the ISO-8601 string with `std.time` helpers; store as Unix epoch seconds.
- **Resume command:** `codex resume <ID>`

### 6.3 Gemini

- **Discovery glob:** `~/.gemini/tmp/*/chats/session-*.jsonl`
- **ID:** filename stem (Gemini does not accept a session ID on the CLI; we keep the stem for display only).
- **Cwd:** Gemini does not store cwd in the session file. The parent directory name is a project hash. Resolve the hash to a real path via `~/.gemini/projects.json` if present; otherwise leave `Cwd` empty and skip chdir on resume.
- **Started at:** first line's `startTime`.
- **User prompts:** lines with `type == "user"` and `content[].text`; concatenate the text parts.
- **Resume command:** `gemini --session-file <Path>` (Gemini's `--resume` takes an index, not an ID, so we pass the file path directly).

## 7. Index

**Location:** `~/.cache/fzag/index.sqlite` (override via `FZAG_CACHE_DIR`). Opened with `PRAGMA journal_mode=WAL`, `synchronous=NORMAL`, `foreign_keys=ON`, `temp_store=MEMORY`.

**Schema (v1):**

```sql
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
-- meta('schema_version', '1') is written on init.

CREATE TABLE IF NOT EXISTS sessions (
    path            TEXT PRIMARY KEY,         -- absolute file path
    agent           TEXT NOT NULL,            -- 'claude' | 'codex' | 'gemini'
    id              TEXT NOT NULL,            -- UUID, or stem for Gemini
    cwd             TEXT,                     -- nullable
    started_at      INTEGER NOT NULL,         -- unix seconds
    updated_at      INTEGER NOT NULL,         -- file mtime, unix seconds
    first_prompt    TEXT NOT NULL,            -- truncated to 160 bytes
    search_corpus   TEXT NOT NULL             -- all user prompts joined, newline-stripped
);

CREATE INDEX IF NOT EXISTS sessions_agent_id   ON sessions(agent, id);
CREATE INDEX IF NOT EXISTS sessions_updated_at ON sessions(updated_at DESC);

CREATE TABLE IF NOT EXISTS user_prompts (
    session_path TEXT NOT NULL,
    idx          INTEGER NOT NULL,            -- 0-based position in the session
    ts           INTEGER NOT NULL,            -- unix seconds
    text         TEXT NOT NULL,
    PRIMARY KEY (session_path, idx),
    FOREIGN KEY (session_path) REFERENCES sessions(path) ON DELETE CASCADE
);
```

Storing `search_corpus` denormalised on `sessions` is deliberate: the picker query is a single sequential scan emitting one row per session, no joins. `user_prompts` is consulted only by the preview subcommand for the focused session.

**Refresh policy on each launch:**

1. Open (or initialise) the database. If `meta.schema_version` differs from the binary's version, drop and recreate.
2. Walk all three discovery globs, collect `(path, mtime)`.
3. In a single transaction:
   - For each discovered path whose `mtime > sessions.updated_at` (or which is absent), parse and `INSERT OR REPLACE`. The cascade clears stale `user_prompts` first.
   - `DELETE FROM sessions WHERE path NOT IN (... discovered ...)` to drop vanished files.
4. Commit.

**`fzag --reindex`** drops both tables and rebuilds from scratch.

**Lookup for resume.** The picker output carries `agent` and `token` (UUID or file path). One indexed query: `SELECT path, cwd FROM sessions WHERE agent=? AND id=? LIMIT 1`. No in-memory map needed; SQLite's covering index handles it.

**Corruption.** If SQLite reports `SQLITE_CORRUPT` or `SQLITE_NOTADB` on open, log a warning to stderr, delete the file, and rebuild. The cache is reconstructible by definition.

**Concurrency.** WAL mode means two `fzag` invocations can read concurrently; the refresh transaction serialises writes. Last writer wins, which is fine because both writers see the same source files.

## 8. Picker

### 8.1 Choice of finder

Shell out to `fzf` by default; fall back to `sk` if `fzf` is not on `$PATH`. Override via `FZAG_FINDER` env var. The finder is invoked with the user's `FZF_DEFAULT_OPTS` left intact so personal config still applies.

### 8.2 Line format

Each session is one tab-separated line:

```
<agent>\t<date>\t<cwd-abbrev>\t<first-prompt>\t<id-or-path>\t<search-corpus>
```

- `agent`: `claude`, `codex`, `gemini`.
- `date`: `YYYY-MM-DD HH:MM`, derived from `StartedAt`.
- `cwd-abbrev`: cwd with `$HOME` collapsed to `~`, truncated from the left to 40 chars if longer.
- `first-prompt`: `FirstPrompt`, newlines replaced with spaces.
- `id-or-path`: opaque token consumed by the preview and resume code (UUID for Claude/Codex, file path for Gemini).
- `search-corpus`: all `UserPrompts` joined with spaces, newlines stripped — this is what fzf actually fuzzy-matches against.

### 8.3 fzf invocation

```
fzf \
  --delimiter=$'\t' \
  --with-nth=1,2,3,4 \
  --nth=6 \
  --preview='fzag preview {1} {5}' \
  --preview-window=right:50%:wrap \
  --ansi --no-sort --tac
```

- `--with-nth=1,2,3,4` shows only the first four columns to the user.
- `--nth=6` restricts matching to the search-corpus field, so typing matches user prompts rather than the cwd/date noise.
- `--no-sort --tac` preserves index order; entries are emitted sorted by `UpdatedAt` descending so the most-recently-touched sessions are at the top.
- The `fzag` string in `--preview` is the absolute path of our own binary (resolved from `std.fs.selfExePathAlloc`), so the preview works even when fzag is not on `$PATH`.

### 8.4 Preview subcommand

`fzag preview <agent> <id-or-path>` is an internal subcommand fzf calls per focused row. It runs `SELECT ts, text FROM user_prompts WHERE session_path=(SELECT path FROM sessions WHERE agent=? AND id=?) ORDER BY idx LIMIT 20` and prints each prompt with its timestamp. No assistant output, no tool calls.

## 9. Resume

On selection:

1. Parse the chosen line's `agent` and `id-or-path`.
2. `SELECT cwd FROM sessions WHERE agent=? AND id=? LIMIT 1`.
3. If `cwd` is non-null and the directory exists, call `std.process.changeCurDir(cwd)`. If the directory is missing, log a warning via `std.log.scoped(.resume)` and continue from the current directory.
4. Build argv per the adapter's resume command and call `std.process.execv(allocator, argv)`. The fzag process is replaced by the agent CLI, which inherits the new cwd.

`execv` is POSIX; that is fine — all three agent CLIs are Unix-only too.

## 10. CLI Surface

```
fzag                          pick across all agents
fzag --claude                 filter to one or more agents (repeatable)
fzag --codex --gemini
fzag --reindex                force full rebuild, then pick
fzag --no-pick                emit the index in picker line format (section 8.2)
                              to stdout and exit; useful for piping/composition
fzag preview <agent> <token>  internal, invoked by fzf
```

Environment variables:

- `FZAG_FINDER` — override the finder binary (`fzf` or `sk`).
- `FZAG_CACHE_DIR` — override the index location (default `~/.cache/fzag`).

## 11. Testing

All tests run via `zig build test`. Use `std.testing.allocator` everywhere — it surfaces leaks with stack traces and is the default lever for memory-safety checks.

- **Adapter unit tests.** Small JSONL fixtures per agent under `test/fixtures/`, exercising: a happy-path session, a session whose `cwd` is missing, a sidechain-only Claude file, a Gemini file whose project hash is unknown. Each test asserts the parsed `Session` (using `std.testing.expectEqualStrings`, `expectEqual`, etc.).
- **Index tests.** Open an SQLite DB at `tmpDir()/index.sqlite`; write fixtures; build index; mutate one fixture's mtime; rebuild; assert only the touched session row changed (compare row hashes).
- **Resume tests.** Expose `resume.spawn` as a function taking an `Spawner` interface (struct with one fn pointer). Tests pass a recording stub; assert the argv and cwd that would have been exec'd for each agent.
- **End-to-end smoke test.** Run `fzag --no-pick` against a tmp directory containing one fixture per agent; assert exactly three lines in the expected format.

`zig build test` is wired in CI to fail on any leak, panic, or assertion failure.

## 12. Linting and CI

- **Local:** `just lint` runs `zig fmt --check src/` and invokes zwanzig over `src/`. Zwanzig is consumed as a built binary: either declared in `build.zig.zon` and exposed as a build step (`zig build lint`), or checked out at a sibling path and called directly. Either way, the local `lint` recipe wraps both into one command. Treat any zwanzig violation as a build failure locally and in CI.
- **CI:** GitHub Actions workflow with three jobs — `build`, `test`, `lint`. The lint job runs zwanzig with `--format sarif` against `src/` and uploads via `github/codeql-action/upload-sarif@v3` so findings show up in the Security tab. Build and test jobs use Zig 0.15.2 from the official tarball (pinned).
- **Pre-commit hook (optional):** `zig fmt --check src/` runs as a pre-commit; zwanzig stays in CI only to keep commits fast.

## 13. Open Questions and Risks

1. **Codex user-prompt shape.** Sampled `session_meta` only; the exact JSON keys for user-input lines need to be confirmed against a real session file during the first day of implementation. The adapter layer isolates this so a misread of the shape only requires touching `adapters/codex.zig`.
2. **Gemini cwd recovery.** If `~/.gemini/projects.json` lacks an entry for a session's project hash, the cwd is unrecoverable. Behaviour: store `cwd = NULL`, display the hash in the list, skip chdir on resume.
3. **SQLite link strategy.** Vendoring the amalgamation keeps the build hermetic but ties us to one sqlite version. If we later want runtime linking against the system sqlite (smaller binary, OS security updates), the change is contained to `build.zig` and the `@cImport`.
4. **Schema migrations.** v1 ships with the schema above. Future bumps detect via `meta.schema_version` and rebuild from scratch — the cache is reconstructible, so we never write a real migration.
5. **Zwanzig false positives.** The first lint pass on greenfield code may surface rules we want to disable for fzag specifically (e.g. for vendored C code under `vendor/sqlite/`). Use zwanzig's `--skip` filter and document the exclusions in `CONTRIBUTING.md`.
