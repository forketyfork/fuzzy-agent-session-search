# fuzzy-agent-session-search (fass)

Unified fuzzy picker for Claude Code, Codex, and Gemini CLI session histories. Type a query, pick a session, `fass` drops you into its original working directory and resumes it.

## Build

With Nix flakes (recommended — pins Zig 0.15.2):

```
nix develop --accept-flake-config
zig build -Doptimize=ReleaseFast
```

Or with Zig 0.15.2 and `fzf` (or `sk`) on `$PATH`:

```
zig build -Doptimize=ReleaseFast
```

The binary lands at `./zig-out/bin/fass`.

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
