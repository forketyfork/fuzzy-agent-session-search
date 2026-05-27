# fzag

Unified fuzzy picker for Claude Code, Codex, and Gemini CLI session histories. Type a query, pick a session, fzag drops you into its original working directory and resumes it.

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

## Usage

```
fzag                      pick across all agents
fzag --claude --gemini    filter to specific agents (repeatable)
fzag --reindex            drop the cache and rebuild
fzag --no-pick            print sessions instead of picking
```

## Configuration

| Env var          | Default              | Purpose                       |
|------------------|----------------------|-------------------------------|
| `FZAG_FINDER`    | `fzf` (else `sk`)    | finder binary                 |
| `FZAG_CACHE_DIR` | `~/.cache/fzag`      | location of `index.sqlite`    |

## Design

See `docs/superpowers/specs/2026-05-27-fzag-design.md`.
