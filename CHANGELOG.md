# Changelog

All notable changes to this skill are documented here. Format: [Keep a Changelog](https://keepachangelog.com/).

## [1.4.0] - 2026-11-02
### Added
- `-I` (`/transfer --inherit`), `-M local`, `-E local`: launch the remote session with this session's own model (last model in the transcript) and effort (`settings.json` `modelSettings.<model>.effortLevel`, else `effortLevel`).
- The copy-mode reason now says how to keep the history (ship the session cwd itself).
- SKILL.md: services on other hosts stay up while local watchers are stopped; check the session cwd before picking the source dir; probe with the final flags; handoff sections for running services, monitors to re-arm and open decisions; a section on relaying later user messages to the remote tmux pane and handing over finished work as a patch.

## [1.3.0] - 2026-11-01
### Added
- Config sync: before the transcript is copied, `~/.claude` is synced on both machines through git (`~/.claude/scripts/claude-config-sync.sh`, private repo claude-config, allowlist `.gitignore`, secret scan). `-K` syncs config only, `-N` skips it. Plugin differences and missing hook paths are reported.
### Fixed
- Memory is never overwritten by rsync: macOS openrsync ignores `--update`, so the two-way memory sync from 1.2.0 could replace newer files with older ones. Memory now travels with the config repo; without it only missing files are copied (`--ignore-existing`), also in the PULLBACK line.

## [1.2.0] - 2026-11-01
### Added
- Sync mode: when the project path already exists on the remote as a checkout of the same repo, resume the same session there instead of falling back to copy mode. Tracked remote changes are saved on `wip/transfer-<ts>`, then the branch (`-B`, default the local one) is fast-forwarded to `origin`.
- Memory is synced both ways in resume and sync mode (remote-only or newer files come home first).

## [1.1.1] - 2026-10-21
### Fixed
- SKILL.md: Remote Control after a resume-mode transfer. The remote joins the same RC entry (same `cse_…` id) as the local process, so the user must `/exit` the local session for RC to reach the remote. Documented how to verify this and how to avoid the Disconnect trap.

## [1.1.0] - 2026-10-21
### Added
- `-M <model>` / `-E <effort>` (`/transfer --model`, `--effort`): launch the remote session with a specific model and effort level; both are validated before anything is sent.
- README, banner, MIT license; first public release as its own repository.

## [1.0.0] - 2026-10-07
### Added
- Resume mode: ship the project to the same absolute path plus the session transcript and memory, then `claude --resume <id>` in tmux under caffeinate.
- Copy-mode fallback seeded with a handoff brief; dry-run probe (`-n`); 2 GiB payload guard and remote disk check.
