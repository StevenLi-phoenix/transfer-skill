#!/usr/bin/env bash
# transfer.sh — move the current Claude Code task to a remote host and keep it running
# there inside tmux.
#
# usage: transfer.sh [-H host] [-m mode] [-b] [-M model] [-E effort] [-f] [-n] [-C] [-s session_id] <src_dir> [handoff.md]
#   -H host  ssh host (default: mini)
#   -m mode  remote claude --permission-mode (default: auto)
#   -b       shorthand for -m bypassPermissions
#   -M model remote claude --model (alias like opus/sonnet/fable or a full id; default: remote's own)
#   -E lvl   remote claude --effort: low|medium|high|xhigh|max (default: remote's own)
#   -f       force: skip the 2 GiB payload guard
#   -n       dry run: print the plan (MODE=resume|copy and why), change nothing remotely
#   -C       copy mode only: fresh remote session seeded with handoff.md (never resume)
#   -s id    session to resume (default: $CLAUDE_CODE_SESSION_ID)
#   handoff.md is required unless -n.
#
# Modes
#   resume (default when possible): the project goes to the SAME absolute path on the remote,
#     the session transcript (<id>.jsonl, <id>/ with subagents + tool-results, memory/) goes to
#     the same ~/.claude/projects/<slug>/, and the remote runs
#     `claude --resume <id> "<preamble>"`. The whole conversation travels, and so does the
#     session id (Remote Control / /rc stays attached). Requirements: the session's cwd is
#     src_dir or inside it (no symlinks), and src_dir does NOT exist on the remote yet — we
#     never merge into existing remote files — and can be created there.
#   copy (fallback, or -C): ~/transfer/<name>-<ts>/ + a fresh session whose first prompt is
#     handoff.md. Memory is copied to the new path's project dir (best effort).
#
# Remote layout: <dest>/.transfer/  (TRANSFER.md, PROMPT.md, run.sh, id, mode, session, base; git-excluded)
# Nothing is cleaned up automatically: the remote copy stays where it is so work can go on
# there. The remote transcript lives in ~/.claude/projects/<slug>/ (PULLBACK line brings it back).
# Prints KEY=VALUE lines on stdout for the caller; logs go to stderr.
set -euo pipefail

HOST=mini
MODE=auto
MODEL=
EFFORT=
FORCE=0
DRY=0
COPY_ONLY=0
SID=${CLAUDE_CODE_SESSION_ID:-}
MAX_BYTES=$((2 * 1024 * 1024 * 1024))
REMOTE_PATH='export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH";'

log() { printf '[transfer %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
usage() { sed -n '5,16p' "$0" >&2; exit 2; }
q() { printf '%q' "$1"; } # quote one arg for the remote shell (openrsync has no --protect-args)

while getopts "H:m:bM:E:fnCs:" o; do
  case $o in
    H) HOST=$OPTARG ;;
    m) MODE=$OPTARG ;;
    b) MODE=bypassPermissions ;;
    M) MODEL=$OPTARG ;;
    E) EFFORT=$OPTARG ;;
    f) FORCE=1 ;;
    n) DRY=1 ;;
    C) COPY_ONLY=1 ;;
    s) SID=$OPTARG ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -ge 1 && $# -le 2 ]] || usage

case $EFFORT in '' | low | medium | high | xhigh | max) ;; *) die "bad -E effort: $EFFORT (low|medium|high|xhigh|max)" ;; esac
MODEL_RE='^[][A-Za-z0-9._:/-]*$' # aliases, full ids, and suffixes like [1m]
[[ $MODEL =~ $MODEL_RE ]] || die "bad -M model: $MODEL"

SRC=$(cd "$1" && pwd -P)
HANDOFF=${2:-}
[[ $SRC != "$HOME" && $SRC != / ]] || die "refusing to ship $SRC as a whole"
if ((DRY == 0)); then
  [[ -n $HANDOFF && -s $HANDOFF ]] || die "handoff file missing or empty: ${HANDOFF:-<none>}"
fi

NAME=$(basename "$SRC" | LC_ALL=C tr -c 'A-Za-z0-9_-' '-' | sed 's/-*$//')
TS=$(date +%Y%m%d-%H%M%S)
ID="${NAME}-${TS}"
SESSION="transfer-${ID}"

# Regenerable env/cache dirs only — anything else (build/, dist/) may be tracked source.
EXCLUDES=(--exclude .venv --exclude venv --exclude node_modules --exclude __pycache__
  --exclude .pytest_cache --exclude .mypy_cache --exclude .ruff_cache --exclude .DS_Store
  --exclude .next --exclude DerivedData --exclude .transfer)

ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" true || die "ssh $HOST unreachable"

# --- local session lookup ---------------------------------------------------------------
SESSION_FILE="" SLUG_DIR="" SESSION_CWD="" SESSION_CWD_P=""
if [[ -n $SID ]]; then
  SESSION_FILE=$(find "$HOME/.claude/projects" -maxdepth 2 -name "$SID.jsonl" -print 2>/dev/null | head -1 || true)
fi
if [[ -n $SESSION_FILE ]]; then
  SLUG_DIR=$(dirname "$SESSION_FILE")
  SESSION_CWD=$(grep -o -m1 '"cwd":"[^"]*"' "$SESSION_FILE" | head -1 | sed 's/^"cwd":"//; s/"$//' || true)
  [[ -n $SESSION_CWD ]] && SESSION_CWD_P=$(cd "$SESSION_CWD" 2>/dev/null && pwd -P || true)
fi

# --- remote probe (read-only) -----------------------------------------------------------
PROBE=$(ssh "$HOST" "bash -s -- $(q "$SRC")" <<'EOS'
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
p=$1
echo "RHOME=$HOME"
echo "RUID=$(id -u)"
echo "RAVAIL_KB=$(df -Pk "$HOME" | awk 'NR==2 {print $4}')"
if command -v claude >/dev/null; then echo "RCLAUDE=$(claude --version 2>/dev/null | head -1)"; else echo "RCLAUDE=missing"; fi
command -v tmux >/dev/null && echo "RTMUX=ok" || echo "RTMUX=missing"
if [ -e "$p" ]; then
  echo "RPATH=exists"
else
  a=$(dirname "$p"); while [ ! -e "$a" ]; do a=$(dirname "$a"); done
  if [ -d "$a" ] && [ -w "$a" ]; then echo "RPATH=ok"; else echo "RPATH=unwritable:$a"; fi
fi
EOS
)
get() { sed -n "s/^$1=//p" <<<"$PROBE" | head -1; }
RHOME=$(get RHOME)
RUID=$(get RUID)
RAVAIL_KB=$(get RAVAIL_KB)
RCLAUDE=$(get RCLAUDE)
RPATH=$(get RPATH)
[[ -n $RHOME ]] || die "remote probe failed: $PROBE"
[[ $RCLAUDE != missing && $(get RTMUX) == ok ]] || die "claude or tmux missing on $HOST"

# --- pick the mode ----------------------------------------------------------------------
KIND=copy
REASON=""
if ((COPY_ONLY)); then REASON="-C given"
elif [[ -z $SID ]]; then REASON="no session id (pass -s or run inside Claude Code)"
elif [[ -z $SESSION_FILE ]]; then REASON="transcript $SID.jsonl not found under ~/.claude/projects"
elif [[ -z $SESSION_CWD ]]; then REASON="could not read the session cwd from the transcript"
elif [[ $SESSION_CWD_P != "$SESSION_CWD" ]]; then REASON="session cwd $SESSION_CWD is missing locally or goes through a symlink"
elif [[ $SESSION_CWD != "$SRC" && $SESSION_CWD != "$SRC"/* ]]; then REASON="session cwd $SESSION_CWD is outside $SRC"
elif [[ $RPATH == exists ]]; then REASON="$SRC already exists on $HOST (resume never merges into existing files; remove it there first or accept copy mode)"
elif [[ $RPATH != ok ]]; then REASON="cannot create $SRC on $HOST (${RPATH#unwritable:} not writable)"
else KIND=resume
fi

if [[ $KIND == resume ]]; then
  DEST=$SRC
  RUN_CWD=$SESSION_CWD
  RSLUG="$RHOME/.claude/projects/$(basename "$SLUG_DIR")"
else
  DEST="$RHOME/transfer/$ID"
  RUN_CWD=$DEST
  # Claude Code's project dir name for a path: '/' and '.' become '-' (DEST is already sanitized).
  RSLUG="$RHOME/.claude/projects/$(printf '%s' "$DEST" | LC_ALL=C sed 's#[^A-Za-z0-9_-]#-#g')"
fi
LOCAL_TMP="/private/tmp/claude-$(id -u)/$(basename "${SLUG_DIR:-none}")/$SID"

log "src=$SRC host=$HOST mode=$KIND dest=$DEST tmux=$SESSION perm=$MODE model=${MODEL:-default} effort=${EFFORT:-default} dry=$DRY"
[[ -n $REASON ]] && log "copy mode because: $REASON"
log "local claude $(claude --version 2>/dev/null | head -1 || echo '?'), remote claude $RCLAUDE"

# --- size + disk guards (local dry-run rsync, no remote writes) -----------------------------
BYTES=$(rsync -an --stats "${EXCLUDES[@]}" "$SRC/" "/tmp/.transfer-size-probe-$$/" \
  | awk -F': ' '/^Total file size/ {gsub(/[^0-9]/, "", $2); print $2}')
BYTES=${BYTES:-0}
if [[ -n $SLUG_DIR ]]; then
  SPATHS=()
  for p in "$SESSION_FILE" "$SLUG_DIR/$SID" "$SLUG_DIR/memory"; do [[ -e $p ]] && SPATHS+=("$p"); done
  SBYTES=$(du -sk "${SPATHS[@]}" 2>/dev/null | awk '{s+=$1} END {print s*1024}' || true)
  BYTES=$((BYTES + ${SBYTES:-0}))
fi
log "payload: $((BYTES / 1024 / 1024)) MiB"
if ((BYTES > MAX_BYTES && FORCE == 0)); then
  die "payload $((BYTES / 1024 / 1024)) MiB > 2 GiB guard; re-run with -f if intended"
fi
NEED_KB=$((BYTES / 1024 + 5 * 1024 * 1024))
log "remote free: $((RAVAIL_KB / 1024 / 1024)) GiB, need ~$((NEED_KB / 1024 / 1024)) GiB"
((RAVAIL_KB > NEED_KB)) || die "not enough disk on $HOST"

emit_common() {
  echo "HOST=$HOST"
  echo "MODE=$KIND"
  [[ -n $REASON ]] && echo "REASON=$REASON"
  echo "DEST=$DEST"
  echo "SESSION=$SESSION"
  [[ $KIND == resume ]] && echo "SESSION_ID=$SID"
  echo "BYTES=$BYTES"
  return 0
}

if ((DRY)); then
  log "dry run: nothing sent"
  emit_common
  echo "DRY=1"
  exit 0
fi

# --- create the destination ---------------------------------------------------------------
if [[ $KIND == resume ]]; then
  # plain mkdir on the final component: fails if someone created the path since the probe
  ssh "$HOST" "mkdir -p $(q "$(dirname "$DEST")") && mkdir $(q "$DEST") && mkdir $(q "$DEST/.transfer")" \
    || die "could not create $DEST on $HOST (appeared since the probe?)"
else
  ssh "$HOST" "mkdir -p $(q "$DEST/.transfer")"
fi

# --- ship code (keeps .git, uncommitted and untracked files) -------------------------------
rsync -a "${EXCLUDES[@]}" "$SRC/" "$HOST:$(q "$DEST")/"
log "rsync done"
# ship-time git HEAD, so it is easy to see later what was done remotely (git log base..)
ssh "$HOST" "cd $(q "$DEST") && { git rev-parse HEAD > .transfer/base 2>/dev/null || rm -f .transfer/base; }"

# --- first prompt + launcher ---------------------------------------------------------------
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
if [[ $KIND == resume ]]; then
  cat >"$TMPD/PROMPT.md" <<EOF
[transfer] This conversation was moved from $(hostname -s):$SRC to $HOST at $(date '+%F %T %Z'). The project is at the same path here and the full history came along; the last tool call before the move shows as interrupted — that was the transfer itself, not a failure.
Read $DEST/.transfer/TRANSFER.md for what differs on this machine and the next steps, then continue the task. Regenerable dirs (node_modules, .venv, caches) were not copied; recreate them as needed. Do not run /transfer again from here. When done, commit on a branch; don't push or deploy unless the conversation already asked for that.
EOF
else
  cp "$HANDOFF" "$TMPD/PROMPT.md"
fi
printf '%s\n' "$ID" >"$TMPD/id"
printf '%s\n' "$KIND" >"$TMPD/mode"
[[ $KIND == resume ]] && printf '%s\n' "$SID" >"$TMPD/session"

if [[ $KIND == resume ]]; then
  CLAUDE_CMD="claude --resume $(q "$SID") --permission-mode $(q "$MODE")"
else
  CLAUDE_CMD="claude --permission-mode $(q "$MODE")"
fi
[[ -n $MODEL ]] && CLAUDE_CMD+=" --model $(q "$MODEL")"
[[ -n $EFFORT ]] && CLAUDE_CMD+=" --effort $(q "$EFFORT")"
cat >"$TMPD/run.sh" <<EOF
#!/bin/bash
# Launched by transfer.sh inside tmux session $SESSION ($KIND mode).
set -uo pipefail
$REMOTE_PATH
DEST=$(q "$DEST")
cd $(q "$RUN_CWD") || cd "\$DEST"
# caffeinate holds a no-sleep assertion (idle/disk/system) for exactly as long as claude runs
CAF=""
command -v caffeinate >/dev/null && CAF="caffeinate -ims"
\$CAF $CLAUDE_CMD "\$(cat "\$DEST/.transfer/PROMPT.md")"
echo "[transfer] claude exited (\$?); the copy stays at \$DEST, shell kept open"
exec zsh -l
EOF
chmod +x "$TMPD/run.sh"
for f in PROMPT.md id mode session run.sh; do
  [[ -e $TMPD/$f ]] && scp -q "$TMPD/$f" "$HOST:$(q "$DEST/.transfer/$f")"
done
scp -q "$HANDOFF" "$HOST:$(q "$DEST/.transfer/TRANSFER.md")"

# keep .transfer/ out of the remote git status
ssh "$HOST" "cd $(q "$DEST") && if [ -d .git ]; then mkdir -p .git/info && { grep -qx '.transfer/' .git/info/exclude 2>/dev/null || echo .transfer/ >> .git/info/exclude; }; fi"

# --- session transcript + memory: as late as possible so the copy holds the most context ---
ssh "$HOST" "mkdir -p $(q "$RSLUG")"
if [[ -n $SLUG_DIR && -d $SLUG_DIR/memory ]]; then
  # --update: never clobber memory files that are newer on the remote
  rsync -a --update "$SLUG_DIR/memory" "$HOST:$(q "$RSLUG")/"
fi
if [[ $KIND == resume ]]; then
  rsync -a "$SESSION_FILE" "$HOST:$(q "$RSLUG")/"
  [[ -d $SLUG_DIR/$SID ]] && rsync -a "$SLUG_DIR/$SID" "$HOST:$(q "$RSLUG")/"
  # per-session tmp (scratchpad, background task outputs): same path only makes sense with the same uid
  if [[ -d $LOCAL_TMP && $RUID == "$(id -u)" ]]; then
    ssh "$HOST" "mkdir -p $(q "$(dirname "$LOCAL_TMP")")"
    rsync -a "$LOCAL_TMP" "$HOST:$(q "$(dirname "$LOCAL_TMP")")/"
  fi
  log "session transcript + memory copied to $HOST:$RSLUG"
fi

# run.sh path quoted twice: once for the ssh shell, once for the `sh -c` tmux runs it with
ssh "$HOST" "$REMOTE_PATH tmux new-session -d -s $(q "$SESSION") -x 200 -y 50 -c $(q "$RUN_CWD") $(q "$(q "$DEST/.transfer/run.sh")")"
log "tmux session started"

# --- get claude past first-run dialogs, then confirm it is working ---
# Both dialogs list "No, exit" first and may default to it, so select the second option.
# Each dialog is answered at most once; a still-visible dialog afterwards means it didn't take.
STATE=unknown
TRUST_SENT=0
BYPASS_SENT=0
PANE=""
for _ in $(seq 1 25); do
  sleep 3
  PANE=$(ssh "$HOST" "$REMOTE_PATH tmux capture-pane -p -t $(q "$SESSION")" 2>/dev/null || true)
  if grep -q '\[transfer\] claude exited' <<<"$PANE"; then
    STATE=exited; break
  elif grep -q 'Yes, I trust this folder' <<<"$PANE" && ((TRUST_SENT == 0)); then
    log "accepting folder-trust dialog"
    ssh "$HOST" "$REMOTE_PATH tmux send-keys -t $(q "$SESSION") Down Enter"
    TRUST_SENT=1
  elif grep -q 'Yes, I accept' <<<"$PANE" && [[ $MODE == bypassPermissions ]] && ((BYPASS_SENT == 0)); then
    log "accepting bypass-permissions warning (mode=$MODE was requested)"
    ssh "$HOST" "$REMOTE_PATH tmux send-keys -t $(q "$SESSION") Down Enter"
    BYPASS_SENT=1
  elif grep -q 'esc to interrupt\|⏵⏵\|shift+tab to cycle' <<<"$PANE"; then
    STATE=running; break
  elif grep -qi 'login\|sign in\|API key' <<<"$PANE"; then
    STATE=needs-login; break
  fi
done
log "remote claude state: $STATE"
[[ $STATE == unknown ]] && log "last pane:" && printf '%s\n' "$PANE" | tail -15 >&2

emit_common
echo "STATE=$STATE"
echo "ATTACH=ssh $HOST -t '$REMOTE_PATH tmux attach -t $SESSION'"
if [[ $KIND == resume ]]; then
  # The remote copy of the transcript is a superset of the local one up to the transfer point;
  # pulling it back overwrites the local tail written after the copy (this report turn).
  # include filters: <id>/ may not exist (no subagents yet), and other sessions in the slug dir stay put
  echo "PULLBACK=rsync -a --include=$(q "$SID.jsonl") --include=$(q "$SID/") --include=$(q "$SID/**") --exclude='*' $HOST:$(q "$RSLUG")/ $(q "$SLUG_DIR")/ && rsync -a --update --include=memory/ --include='memory/**' --exclude='*' $HOST:$(q "$RSLUG")/ $(q "$SLUG_DIR")/"
fi
