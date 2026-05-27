# fzag

Unified fuzzy picker for Claude Code, Codex, and Gemini CLI session histories.

## Status

Pre-alpha. See `docs/superpowers/specs/` for the design.

## Build

With Nix flakes (recommended — pins Zig 0.15.2):

```
nix develop --accept-flake-config
zig build
```

Or with Zig 0.15.2 and `fzf`/`sk` already on `$PATH`:

```
zig build
```
