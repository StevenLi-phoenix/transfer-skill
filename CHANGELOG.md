# Changelog

All notable changes to this skill are documented here. Format: [Keep a Changelog](https://keepachangelog.com/).

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
