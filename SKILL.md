---
name: transfer
description: Use when user invokes /transfer (or says "offload this to mini", "move this task to the mac mini", "continue this on mini"). Aborts the current task locally and moves it to the Mac mini — by default by copying the project to the same absolute path plus this session's transcript and resuming the SAME conversation there (`claude --resume`), falling back to a fresh session seeded with a handoff prompt — inside tmux, wrapped in caffeinate, in auto permission mode. Invoking /transfer is the user's explicit authorization to copy the project and session transcript to the remote host and launch Claude there.
---

# Transfer — move the current task to another machine

Stop working here and continue the task on the Mac mini (`ssh mini`). By default the **same conversation** continues there: the project goes to the same absolute path, this session's transcript goes along, and the remote runs `claude --resume <session-id>`. The full history, memory and session id all travel, and the remote attaches to the **same** Remote Control entry (same `cse_…` id) — see step 6. The heavy lifting is `transfer.sh` next to this file. Your job is to stop cleanly, write the handoff, run the script, and report.

## Arguments

```
/transfer                    # move the task to mini (resume mode when possible), auto permission mode
/transfer <hint>             # extra focus/instructions for the remote session
/transfer --host <h>         # another ssh host (needs claude + tmux there)
/transfer --mode <m>         # remote --permission-mode (auto|acceptEdits|bypassPermissions|manual|plan)
/transfer --model <m>        # (-M) remote --model, e.g. opus / sonnet / fable or a full id (default: remote's own)
/transfer --effort <lvl>     # (-E) remote --effort: low|medium|high|xhigh|max (default: remote's own)
/transfer --branch <b>       # (-B) sync mode: branch the remote checkout is fast-forwarded to (default: local current branch)
/transfer --copy             # (-C) fresh remote session from the handoff instead of resuming
/transfer --force            # allow payload > 2 GiB
```

## Modes (the script picks; `MODE=` in its output says which)

| | resume (default) | sync (path exists remotely as a git checkout) | copy (fallback, or `-C`) |
|---|---|---|---|
| Remote path | same absolute path as here, created fresh | same absolute path, the remote's **own** checkout | `~/transfer/<name>-<ts>/` |
| Code | rsync of the working tree (incl. `.git`, uncommitted, untracked) | **no rsync**: tracked remote changes go to `wip/transfer-<ts>`, then `<branch>` is fast-forwarded to `origin/<branch>`; remote untracked files stay | rsync |
| Conversation | **same session**: `<id>.jsonl` + `<id>/` (subagents, tool-results) copied to the same `~/.claude/projects/<slug>/`, then `claude --resume <id>` | same as resume | new session; first prompt is the full handoff |
| Memory | two-way `--update` sync (newer file wins, nothing deleted) | same as resume | copied to the new slug (best effort) |
| First prompt | short preamble telling it that it moved and to read `.transfer/TRANSFER.md` | same, plus the synced branch and any wip branch | the handoff itself |
| Needs | session cwd is the source dir or inside it (no symlinks); the path does **not** exist on the remote yet and can be created | same session-cwd rule; remote `origin` is the same repo (ssh/https forms match); `origin/<branch>` exists; the fast-forward is clean | nothing |

Resume and sync need the identical path because Claude Code finds sessions by the project slug derived from the cwd, and the transcript is full of absolute paths that must stay valid. The script never rsyncs into an existing remote directory. When the path exists and is a checkout of the same repo, it uses sync mode; otherwise it falls back to copy mode and prints the reason in `REASON=`. Don't delete a remote directory yourself.

**Sync mode ships only what is pushed.** Local uncommitted changes (`LOCAL_DIRTY=1`) and unpushed commits (`LOCAL_AHEAD>0`) stay here. If they matter, commit and push them (only when the user allowed pushing), or use `-C`. If the remote branch has diverged or untracked files block the fast-forward, the script stops before launching anything; report the error rather than forcing it.

Nothing is cleaned up automatically. The remote copy stays where it is so the user can keep working there.

## Sequence

### 1. Abort locally
- Make **no further progress** on the task. Don't finish "just one more step".
- Stop background work **this session** started (TaskStop on its own tasks/agents; kill only PIDs you launched, after checking the command line). Never touch other sessions' processes.
- Do not commit, stash, reset or clean anything locally. The rsync ships the working tree as it is, and the local copy stays untouched as the fallback.

### 2. Pick the source dir
The project root the task is in: `git rev-parse --show-toplevel` from the cwd, else the cwd. If that's `$HOME` or `/`, stop and ask which directory to ship.

### 3. Probe
```bash
~/.claude/skills/transfer/transfer.sh -n [-H host] [-B branch] [-C] <src_dir>
```
A dry run that sends nothing. It prints `MODE=resume|sync|copy`, `REASON=` (when it falls back), the sizes, and the remote dest. The session id defaults to `$CLAUDE_CODE_SESSION_ID`, which the Bash tool environment provides. Pass `-s <id>` only to move a different session.

### 4. Write the handoff
Write `<scratchpad>/TRANSFER.md` (scratchpad dir from the system prompt; else `/tmp`). Never put secret values in it (`.env` files ship via rsync without being read).

- **Resume/sync mode:** the remote session already has the whole conversation, so keep it short. Cover only what the history can't tell it:

  ```
  # Transfer: <brief title>

  ## Moved
  From <local host>:<path> at <date/time> to <remote host>, same path, same session.

  ## What differs on the remote
  <runtime versions that differ, missing deps (node_modules/.venv were not copied → recreate), network/quotas, anything machine-specific you noticed during the probe>

  ## Next steps
  <prioritized, concrete; where the conversation left off>

  ## Rules there
  - Don't run /transfer again from the remote.
  - Don't push, deploy or touch other machines unless the conversation already asked for it. Commit on a branch when done; the user pulls it back.

  ## User's extra instructions
  <the /transfer <hint>, if any>
  ```

- **Copy mode:** the remote session has **zero** history, so this file is its whole world. Use the full structure: Origin, Goal (quote the user's request), Done so far, Current state (incl. the last error verbatim), Tried and failed, Next steps, Remote environment notes, User's extra instructions. Be specific: absolute paths, exact commands, decisions and their reasons. Durable facts from this project's memory (`~/.claude/projects/<slug>/memory/`) are copied to the new path's project dir on a best-effort basis, but restate the important ones.

### 5. Ship and launch
```bash
~/.claude/skills/transfer/transfer.sh [-H host] [-m mode] [-M model] [-E effort] [-B branch] [-C] [-f] <src_dir> <scratchpad>/TRANSFER.md
```
The script:
- probes the remote (read-only), picks the mode, and checks the payload size (2 GiB guard) and remote disk (payload + 5 GiB)
- `rsync -a` the project, excluding regenerable dirs (.venv, venv, node_modules, __pycache__, lint/test caches, .next, DerivedData, .DS_Store). `.git` and uncommitted/untracked work go along
- puts TRANSFER.md, PROMPT.md, run.sh, id, mode, session and the ship-time git HEAD (`base`) in `<dest>/.transfer/`, and adds `.transfer/` to `.git/info/exclude`
- copies the session last, so it holds the most context: `<id>.jsonl`, `<id>/`, `memory/` (with `--update`, so newer remote memory files are never overwritten), plus the per-session tmp dir (scratchpad, task outputs) when the remote uid matches
- starts tmux session `transfer-<name>-<ts>` running `caffeinate -ims claude [--resume <id>] --permission-mode <mode> "<PROMPT.md>"`. The shell stays open after claude exits
- answers the folder-trust dialog (and the bypass warning only when mode is bypassPermissions), then waits until claude is up
- prints `HOST= MODE= [REASON=] DEST= SESSION= [SESSION_ID=] BYTES= STATE= ATTACH= [PULLBACK=]` on stdout

`STATE`:
- `running`: good.
- `needs-login`: tell the user to run `claude` once on the remote and log in.
- `exited` or `unknown`: capture the pane (`tmux capture-pane -p -S -100 -t <SESSION>`), diagnose, fix, and relaunch. Don't report success.

### 6. Report and stop
Brief, in the user's language:
- the mode (and `REASON` if it fell back), the remote dir, the tmux session, and `STATE`
- attach: the `ATTACH` line (detach with `Ctrl-b d`). In resume mode the user can also follow through Remote Control, but the RC list shows **one** entry (same title, same `cse_…` id) that both machines' processes are bridged to, and the local one keeps answering it. Tell the user to `/exit` the local session right after the transfer so the RC entry is driven by the remote only. Verify with `jq '.replBridgePlaceholders' ~/.claude.json` on both ends (same cse id, different pids). On the remote, `/rc` in the autocomplete reads "Disconnect Remote Control" when it is already connected, so don't press Enter there.
- getting work back: `git fetch <host>:<DEST> <branch>:<branch>` once the remote commits. In resume mode, the `PULLBACK` line brings the remote transcript and memory back, so the conversation can later be resumed here.
- the local working tree is left untouched. **Don't keep using this session locally after a resume-mode transfer**: both machines now hold the same session id, so they would fork.

Then end the turn. Don't keep working on the task locally.

## Gotchas
- The last tool call before the copy (the transfer itself) shows as `Interrupted` in the resumed remote session. The preamble tells it this is expected.
- Claude's trust and bypass dialogs list "No, exit" first and can default to it, so a plain Enter exits. The script sends Down+Enter once per dialog.
- Non-interactive ssh on the mini lacks `~/.local/bin` and `/opt/homebrew/bin` in PATH. The script prefixes them on every remote command.
- macOS ships openrsync (2.6.9-compatible): there's no `--protect-args`, so remote paths are passed through `printf %q`. `/bin/bash` is 3.2, and the script stays compatible with it.
- A tool call the user rejects mid-run may already have executed. Check `tmux ls` on the remote before assuming nothing launched.
- Old copy-mode leftovers under `~/transfer/` on the mini are not cleaned automatically any more. List them with `ssh mini 'du -sh ~/transfer/*'` and remove them by hand when the user asks.
