# AGENTS.md

Bash scripts that calibrate and encode Blu-ray remuxes to HEVC Main10
within an HEVC level (4.1 Main at 1080p, 5.1 High at 2160p), so any decoder
of that level plays them. README.md has the usage.

## Layout

- `hevc-1080p-sdr.sh`, `hevc-2160p-hdr.sh`: single host. `hevc-farm.sh`:
  either profile over SSH workers. Each entry script only runs sections
  0–5 in order; the work is in `lib/`.
- `lib/profile-*.sh`: everything profile-specific. The rest of `lib/` is
  shared: `calibrate` (CRF walk and gates), `score` (whole-film VMAF NEG,
  CAMBI, XPSNR), `parts` (encode and mkvmerge mux), `farm` and `remote`
  (scheduler, chunks, workers), `mux`, `probe`, `ui`, `util`.
- `nix/flake.nix`: the tools, the dev shell and one package per script.

## Develop

- `nix develop path:./nix` gives every tool, shellcheck included.
- `shellcheck -x hevc-*.sh lib/*.sh` must pass; `.shellcheckrc` says why
  some checks are off. Fix findings rather than disabling them inline.
- Match the existing style: `set -euo pipefail`, 4-space indent, a comment
  above each function stating its contract, and comments only for why.
  Output goes through the `ui.sh` helpers and fits 78 columns.
- The `.analysis` cache is keyed on a fingerprint of the encode and scoring
  settings and functions; `.chunks` on `farm_job_chunk` and `score_frames`.
  Changing those invalidates stored results, on purpose.
- The level and VBV are the compatibility contract: do not raise them or
  add tools the level forbids.
- Workers take their tools from the flake at the master's commit: a change
  under `nix/` must be committed and pushed before a farm run (or set
  `FARM_REF`).

## Safety

- Never pass shell globs to ffmpeg, and never `-y` into a directory with
  sources: a glob once overwrote a 95 GiB remux. Quote exact paths.
- Films in the repo root are sources. Do not delete or move them unasked.

## Test

- Use short clips, never full films, for code changes. For farm tests,
  copy the code elsewhere, set `CHUNK_SECONDS=10` and
  `CHUNK_WINDOWS=(2 4 6)` in `lib/farm.sh`, and set `FARM_REF` to a pushed
  commit.
- Small `PRESETS` (e.g. `slow:14`) and `--yes` keep runs short; `script
  -qec '…' /dev/null` gives the scripts a terminal.
- A change is done when section 5's checks pass on a clip, and `--dry-run`
  still prints sensible commands for the other profile.

## Git

- The repository is public: no film titles in commit messages.
- Commit and push only when asked.
