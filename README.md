# fuzzy-agent-session-search (fass)

Unified fuzzy picker for Claude Code, Codex, and Gemini CLI session histories. Type a query, pick a session, `fass` drops you into its original working directory and resumes it.

## Build

With Nix flakes (recommended — pins Zig 0.16.0):

```
nix develop --accept-flake-config
zig build -Doptimize=ReleaseFast
```

Or with Zig 0.16.0 and `fzf` (or `sk`) on `$PATH`:

```
zig build -Doptimize=ReleaseFast
```

The binary lands at `./zig-out/bin/fass`.

On macOS, install the current Xcode Command Line Tools (`xcode-select --install`)
or select an Xcode installation with `xcode-select`. Zig uses the selected SDK;
an older macOS SDK is not required. The Nix shell uses the system Xcode tools.

## Development

Run `just ci` inside `nix develop` to build, run unit and end-to-end tests, check
formatting, and run the pinned zwanzig analyzer. CI runs these checks on both
Linux and macOS. `zig build test-e2e` runs the end-to-end tests separately.

The executable receives its allocator, I/O context, and environment through
Zig's `std.process.Init`. Filesystem and process operations take an explicit
`std.Io`; tests use `std.testing.io`. SQLite is vendored and compiled into the
binary, with its Zig bindings generated from `sqlite3.h` by `build.zig`.

## Usage

```
fass                      pick across all agents
fass --claude --gemini    filter to specific agents (repeatable)
fass --reindex            drop the cache and rebuild
fass --no-pick            print sessions instead of picking
```

## Configuration

| Env var          | Default              | Purpose                       |
|------------------|----------------------|-------------------------------|
| `FASS_FINDER`    | `fzf` (else `sk`)    | finder binary                 |
| `FASS_CACHE_DIR` | `~/.cache/fass`      | location of `index.sqlite`    |

## Design

See `docs/superpowers/specs/2026-05-27-fass-design.md`.
