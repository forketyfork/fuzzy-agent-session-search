# Release Pipeline — Design

Date: 2026-05-27
Status: Approved

## Goal

Publish GitHub Release artifacts for fass on four targets — Linux x86_64,
Linux aarch64, macOS x86_64, macOS aarch64 — whenever a `vMAJOR.MINOR.PATCH`
tag is pushed to the repository.

## Trigger and shape

A new workflow `.github/workflows/release.yml` fires on `push` of tags
matching `v*.*.*`. It has two jobs:

1. `validate` (ubuntu-latest, Nix-based): runs a pre-flight script that
   verifies the tag and version, then runs the same `just ci` pipeline as
   the regular CI workflow.
2. `release` (ubuntu-latest, single runner): cross-compiles the four Zig
   targets, packages each as a `tar.gz`, computes SHA-256 checksums, and
   uploads everything as GitHub Release assets via
   `softprops/action-gh-release` with auto-generated release notes.

`release` declares `needs: validate`, so the four-target build runs only
after pre-flight passes.

No `workflow_dispatch` trigger for now; pushing a tag is the single
entry point. This can be added later if needed.

## Components

### `scripts/release-check.sh`

A Bash script invoked by the `validate` job with the tag name as its
single argument. Adapted from the zwanzig project's release-check.sh.
It performs the following, in order, exiting non-zero on the first
failure:

- Verify the argument matches `^v[0-9]+\.[0-9]+\.[0-9]+$`.
- Verify `git status --porcelain` is empty.
- Parse the `.version` field from `build.zig.zon` and verify it equals
  the tag with the leading `v` stripped (e.g. tag `v0.2.0` requires
  `.version = "0.2.0"`).
- Run `just ci` (build + test + zwanzig lint) inside the Nix dev shell.

The doc-tag scan present in zwanzig's script is omitted: the fass
README does not currently reference release tags. If that changes, the
scan can be added back as a no-op-when-no-matches helper.

The script must be executable and use `set -euo pipefail`.

### `LICENSE`

A new MIT LICENSE file at the repository root, copyright "Forketyfork"
for the year 2026. Added as part of this change so the release artifact
bundle can include it.

### `.github/workflows/release.yml`

The new workflow file. Permissions: `contents: write` (needed by
`softprops/action-gh-release` to create the release and upload assets).

#### Job: `validate`

Runner: `ubuntu-latest`.

Steps:

1. `actions/checkout@v4`.
2. `cachix/install-nix-action@v31` with flakes enabled.
3. `actions/cache@v4` for `.zig-cache`, keyed similarly to `ci.yml`.
4. `cachix/cachix-action@v15` with name `forketyfork` and
   `CACHIX_AUTH_TOKEN` secret (mirrors `ci.yml`).
5. Run `scripts/release-check.sh "${{ github.ref_name }}"` inside the
   Nix dev shell: `nix develop --accept-flake-config --command
   ./scripts/release-check.sh "${{ github.ref_name }}"`.

#### Job: `release`

Runner: `ubuntu-latest`. `needs: validate`.

Steps:

1. `actions/checkout@v4`.
2. `mlugg/setup-zig@v2` with `version: 0.15.2`. (We use `setup-zig`
   here, not Nix, because the release job needs only Zig — not the
   broader dev shell — and `setup-zig` is faster.)
3. `actions/cache@v4` for `.zig-cache`.
4. For each row in the target table below, run:
   ```
   zig build -Doptimize=ReleaseFast -Dtarget=<triple>
   stage="dist/fass-${TAG}-<suffix>"
   mkdir -p "$stage"
   cp zig-out/bin/fass LICENSE README.md "$stage/"
   tar -czf "fass-${TAG}-<suffix>.tar.gz" -C dist "fass-${TAG}-<suffix>"
   rm -rf zig-out
   ```
   The `rm -rf zig-out` between iterations guarantees we never package
   a stale binary if a future `zig build` step exits early.
5. After all four targets build, compute checksums:
   ```
   sha256sum fass-${TAG}-*.tar.gz > fass-${TAG}-checksums.txt
   ```
6. `softprops/action-gh-release@v3` with:
   - `files: |\n  fass-${TAG}-*.tar.gz\n  fass-${TAG}-checksums.txt`
   - `generate_release_notes: true`
   - `fail_on_unmatched_files: true`

Target table:

| Zig target triple    | Asset suffix    |
|----------------------|-----------------|
| `x86_64-linux-gnu`   | `linux-x86_64`  |
| `aarch64-linux-gnu`  | `linux-aarch64` |
| `x86_64-macos`       | `macos-x86_64`  |
| `aarch64-macos`      | `macos-aarch64` |

Linux targets use `-gnu` (dynamic glibc). Switching to `-musl` for
static binaries is a future option but not needed for v1.

## Data flow

```
git tag v0.2.0 && git push --tags
  │
  ▼ release.yml fires (tag push)
  │
  ▼ validate (ubuntu-latest, Nix shell)
  │   checkout → install nix → cache zig+nix
  │   → scripts/release-check.sh v0.2.0
  │     verifies tag format, working tree clean,
  │     build.zig.zon version == 0.2.0,
  │     runs `just ci`
  │
  ▼ release (ubuntu-latest, setup-zig)
  │   checkout → setup-zig 0.15.2 → cache .zig-cache
  │   for each target:
  │     zig build -Doptimize=ReleaseFast -Dtarget=<triple>
  │     package fass + LICENSE + README into tar.gz
  │   sha256sum *.tar.gz > fass-v0.2.0-checksums.txt
  │   softprops/action-gh-release@v3
  │     uploads four tarballs + checksums, with
  │     auto-generated release notes
  │
  ▼ GitHub Release for v0.2.0 published.
```

## Error handling

- **Tag format wrong** (e.g. `v0.2`, `release-0.2.0`): `release-check.sh`
  exits non-zero; validate fails; release never runs.
- **`build.zig.zon` version does not match tag**: `release-check.sh`
  fails; validate fails. Fix is to bump `.version` and re-tag.
- **Working tree dirty** at validate time: `release-check.sh` fails.
  Defensive — checkout is fresh — but cheap to keep.
- **`just ci` fails** (test/lint regression): validate fails. CI on
  main should have caught this before tagging; this is a backstop.
- **Cross-compile fails for one target**: that step fails; release job
  fails before any assets are uploaded (upload step runs only after
  all four `zig build` invocations succeed). Re-run the workflow from
  the GitHub Actions UI after fixing the underlying issue; if a code
  change is required, delete the tag, push the fix, and re-tag.
- **Upload step fails (network, GitHub outage)**: re-run the workflow.
  `softprops/action-gh-release` overwrites existing assets, so the
  re-run is idempotent.

## Testing strategy

Manual smoke test using a throwaway tag:

1. On a branch off `main`, set `.version = "0.0.0"` in
   `build.zig.zon`, commit, and push the branch.
2. Push tag `v0.0.0` pointing at the branch HEAD.
3. Observe `validate` succeed and `release` produce four tarballs +
   checksums.
4. Download each tarball, extract, and run `file fass` to confirm the
   expected architecture / format:
   - linux-x86_64: `ELF 64-bit LSB executable, x86-64`
   - linux-aarch64: `ELF 64-bit LSB executable, ARM aarch64`
   - macos-x86_64: `Mach-O 64-bit executable x86_64`
   - macos-aarch64: `Mach-O 64-bit executable arm64`
5. For Linux artifacts: execute on a Linux host to confirm the binary
   runs (a smoke `fass --help` or equivalent is enough).
6. Verify each tarball's SHA-256 matches the value in
   `fass-v0.0.0-checksums.txt`.
7. Delete the test tag and the draft release.

No automated tests are added for this change — it is infrastructure,
and the release-check.sh script is short enough to dry-run locally
(`bash scripts/release-check.sh v0.1.0` against the current tree).

## Out of scope

- Code signing or notarization of macOS binaries.
- Homebrew tap / Nix flake output publication. (Future work.)
- Windows builds. (Project not currently targeting Windows.)
- Static `musl` Linux builds.
- `workflow_dispatch` manual trigger.
- A `CHANGELOG.md`. Auto-generated release notes cover this for now.
