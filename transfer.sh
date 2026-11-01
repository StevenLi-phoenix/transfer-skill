#!/usr/bin/env bash
# transfer.sh — move the current Claude Code task to a remote host and keep it running
# there inside tmux.
#
# usage: transfer.sh [-H host] [-m mode] [-b] [-M model] [-E effort] [-B branch] [-f] [-n] [-C] [-s session_id] <src_dir> [handoff.md]
#   -H host  ssh host (default: mini)
#   -m mode  remote claude --permission-mode (default: auto)
#   -b       shorthand for -m bypassPermissions
#   -M model remote claude --model (alias like opus/sonnet/fable or a full id; default: remote's own)
#   -E lvl   remote claude --effort: low|medium|high|xhigh|max (default: remote's own)
#   -B br    sync mode: branch to check out and fast-forward to origin/<br> (default: local current branch)
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
#   sync (when src_dir already exists on the remote as a git checkout of the same origin):
#     same session as resume, but the code is NOT rsynced. The remote checkout keeps its own
#     untracked files; tracked uncommitted changes there are committed to wip/transfer-<ts>,
#     then the branch (-B, default: local current branch) is fast-forwarded to origin/<branch>.
#     Local uncommitted or unpushed work does NOT travel (LOCAL_DIRTY/LOCAL_AHEAD report it).
#   copy (fallback, or -C): ~/transfer/<name>-<ts>/ + a fresh session whose first prompt is
#     handoff.md. Memory is copied to the new path's project dir (best effort).
# Memory: in resume/sync mode it is synced both ways first (remote→local, then local→remote,
# both with --update: the newer copy of each file wins, nothing is deleted).
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
BRANCH=
MAX_BYTES=$((2 * 1024 * 1024 * 1024))
REMOTE_PATH='export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH";'

log() { printf '[transfer %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
usage() { sed -n '5,17p' "$0" >&2; exit 2; }
q() { printf '%q' "$1"; } # quote one arg for the remote shell (openrsync has no --protect-args)
# git remote URL -> host/owner/repo, so git@host:o/r.git and https://host/o/r match
repo_id() { sed -E 's#^[a-z+]+://##; s#^[^@/]*@##; s#:#/#; s#\.git$##; s#/+$##' <<<"$1" | tr 'A-Z' 'a-z'; }

while getopts "H:m:bM:E:B:fnCs:" o; do
  case $o in
    H) HOST=$OPTARG ;;
    m) MODE=$OPTARG ;;
    b) MODE=bypassPermissions ;;
    M) MODEL=$OPTARG ;;
    E) EFFORT=$OPTARG ;;
    B) BRANCH=$OPTARG ;;
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
BRANCH_RE='^[A-Za-z0-9._/-]*$'
[[ $BRANCH =~ $BRANCH_RE ]] || die "bad -B branch: $BRANCH"

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

# --- local git facts (for sync mode) ----------------------------------------------------
LORIGIN="" LBRANCH="" LDIRTY=0 LAHEAD=""
if git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1; then
  LORIGIN=$(git -C "$SRC" remote get-url origin 2>/dev/null || true)
  LBRANCH=$(git -C "$SRC" branch --show-current 2>/dev/null || true)
  [[ -n $(git -C "$SRC" status --porcelain --untracked-files=no 2>/dev/null) ]] && LDIRTY=1
fi
[[ -n $BRANCH ]] || BRANCH=$LBRANCH
if [[ -n $LORIGIN && -n $BRANCH ]]; then
  LAHEAD=$(git -C "$SRC" rev-list --count "origin/$BRANCH..$BRANCH" 2>/dev/null || true)
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
  if git -C "$p" rev-parse --git-dir >/dev/null 2>&1; then
    echo "RORIGIN=$(git -C "$p" remote get-url origin 2>/dev/null)"
    echo "RBRANCH=$(git -C "$p" branch --show-current 2>/dev/null)"
    echo "RDIRTY=$(git -C "$p" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')"
  fi
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
RORIGIN=$(get RORIGIN)
RBRANCH=$(get RBRANCH)
RDIRTY=$(get RDIRTY)
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
elif [[ $RPATH == exists && -n $LORIGIN && -n $RORIGIN && $(repo_id "$RORIGIN") == "$(repo_id "$LORIGIN")" && -n $BRANCH ]]; then KIND=sync
elif [[ $RPATH == exists ]]; then REASON="$SRC already exists on $HOST and is not a git checkout of the same origin (${RORIGIN:-no origin}) with a known branch; resume never merges into existing files"
elif [[ $RPATH != ok ]]; then REASON="cannot create $SRC on $HOST (${RPATH#unwritable:} not writable)"
else KIND=resume
fi

if [[ $KIND == resume || $KIND == sync ]]; then
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
if [[ $KIND == sync ]]; then
  log "sync: remote checkout on '${RBRANCH:-detached}' with $RDIRTY tracked change(s) -> will be on '$BRANCH' at origin/$BRANCH"
  ((LDIRTY)) && log "WARNING: local tracked changes in $SRC do NOT travel in sync mode (commit + push first if they matter)"
  [[ -n $LAHEAD && $LAHEAD != 0 ]] && log "WARNING: local $BRANCH is $LAHEAD commit(s) ahead of origin; push first or they won't be there"
fi
log "local claude $(claude --version 2>/dev/null | head -1 || echo '?'), remote claude $RCLAUDE"

# --- size + disk guards (local dry-run rsync, no remote writes) -----------------------------
BYTES=0
if [[ $KIND != sync ]]; then
  BYTES=$(rsync -an --stats "${EXCLUDES[@]}" "$SRC/" "/tmp/.transfer-size-probe-$$/" \
    | awk -F': ' '/^Total file size/ {gsub(/[^0-9]/, "", $2); print $2}')
  BYTES=${BYTES:-0}
fi
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
  [[ $KIND == resume || $KIND == sync ]] && echo "SESSION_ID=$SID"
  if [[ $KIND == sync ]]; then
    echo "BRANCH=$BRANCH"
    echo "LOCAL_DIRTY=$LDIRTY"
    echo "LOCAL_AHEAD=${LAHEAD:-?}"
  fi
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
if [[ $KIND == sync ]]; then
  # save tracked remote changes on a wip branch, then fast-forward the target branch
  SYNC_OUT=$(ssh "$HOST" "bash -s -- $(q "$DEST") $(q "$BRANCH") $(q "$TS")" <<'EOS'
set -euo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$1"; br=$2; ts=$3
git fetch -q origin
git rev-parse --verify -q "origin/$br" >/dev/null || { echo "no origin/$br on the remote" >&2; exit 3; }
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  prev=$(git branch --show-current); prev=${prev:-$(git rev-parse HEAD)}
  git switch -q -c "wip/transfer-$ts"
  git add -u
  git commit -q -m "wip: uncommitted changes found on $(hostname -s) before transfer $ts"
  echo "WIP=wip/transfer-$ts"
  git switch -q "$prev" 2>/dev/null || git switch -q --detach "$prev"
fi
if git rev-parse --verify -q "refs/heads/$br" >/dev/null; then git switch -q "$br"; else git switch -q -c "$br" --track "origin/$br"; fi
git merge -q --ff-only "origin/$br"
echo "SYNCED=$(git rev-parse --short HEAD) $(git log -1 --format=%s | cut -c1-60)"
mkdir -p .transfer
EOS
  ) || die "git sync on $HOST failed (remote branch diverged, or untracked files block the fast-forward); nothing launched"
  while IFS= read -r l; do log "sync: $l"; done <<<"$SYNC_OUT"
  WIP=$(sed -n 's/^WIP=//p' <<<"$SYNC_OUT")
elif [[ $KIND == resume ]]; then
  # plain mkdir on the final component: fails if someone created the path since the probe
  ssh "$HOST" "mkdir -p $(q "$(dirname "$DEST")") && mkdir $(q "$DEST") && mkdir $(q "$DEST/.transfer")" \
    || die "could not create $DEST on $HOST (appeared since the probe?)"
else
  ssh "$HOST" "mkdir -p $(q "$DEST/.transfer")"
fi

# --- ship code (keeps .git, uncommitted and untracked files) -------------------------------
if [[ $KIND != sync ]]; then
  rsync -a "${EXCLUDES[@]}" "$SRC/" "$HOST:$(q "$DEST")/"
  log "rsync done"
fi
# ship-time git HEAD, so it is easy to see later what was done remotely (git log base..)
ssh "$HOST" "cd $(q "$DEST") && { git rev-parse HEAD > .transfer/base 2>/dev/null || rm -f .transfer/base; }"

# --- first prompt + launcher ---------------------------------------------------------------
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
if [[ $KIND == sync ]]; then
  cat >"$TMPD/PROMPT.md" <<EOF
[transfer] This conversation was moved from $(hostname -s):$SRC to $HOST at $(date '+%F %T %Z'). The project is at the same path here: this machine's own git checkout, now on '$BRANCH' fast-forwarded to origin/$BRANCH${WIP:+ (its earlier uncommitted changes were saved on branch $WIP)}. Local uncommitted work from the other machine did not come along. The full conversation history came along; the last tool call before the move shows as interrupted — that was the transfer itself, not a failure.
Read $DEST/.transfer/TRANSFER.md for what differs on this machine and the next steps, then continue the task. Do not run /transfer again from here. When done, commit on a branch; don't push or deploy unless the conversation already asked for that.
EOF
elif [[ $KIND == resume ]]; then
  cat >"$TMPD/PROMPT.md" <<EOF
[transfer] This conversation was moved from $(hostname -s):$SRC to $HOST at $(date '+%F %T %Z'). The project is at the same path here and the full history came along; the last tool call before the move shows as interrupted — that was the transfer itself, not a failure.
Read $DEST/.transfer/TRANSFER.md for what differs on this machine and the next steps, then continue the task. Regenerable dirs (node_modules, .venv, caches) were not copied; recreate them as needed. Do not run /transfer again from here. When done, commit on a branch; don't push or deploy unless the conversation already asked for that.
EOF
else
  cp "$HANDOFF" "$TMPD/PROMPT.md"
fi
printf '%s\n' "$ID" >"$TMPD/id"
printf '%s\n' "$KIND" >"$TMPD/mode"
[[ $KIND == resume || $KIND == sync ]] && printf '%s\n' "$SID" >"$TMPD/session"

if [[ $KIND == resume || $KIND == sync ]]; then
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
  if [[ $KIND == resume || $KIND == sync ]]; then
    # same slug on both ends: pull remote-only/newer memory home first, so this is a two-way sync
    PULLED=$(rsync -a --update --itemize-changes "$HOST:$(q "$RSLUG/memory")/" "$SLUG_DIR/memory/" 2>/dev/null | grep '^>f' | cut -c13- || true)
    [[ -n $PULLED ]] && log "memory pulled from $HOST (newer there): $(tr '\n' ' ' <<<"$PULLED")"
  fi
  # --update: never clobber memory files that are newer on the remote
  rsync -a --update "$SLUG_DIR/memory" "$HOST:$(q "$RSLUG")/"
fi
if [[ $KIND == resume || $KIND == sync ]]; then
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
[[ -n ${WIP:-} ]] && echo "WIP=$WIP"
echo "STATE=$STATE"
echo "ATTACH=ssh $HOST -t '$REMOTE_PATH tmux attach -t $SESSION'"
if [[ $KIND == resume || $KIND == sync ]]; then
  # The remote copy of the transcript is a superset of the local one up to the transfer point;
  # pulling it back overwrites the local tail written after the copy (this report turn).
  # include filters: <id>/ may not exist (no subagents yet), and other sessions in the slug dir stay put
  echo "PULLBACK=rsync -a --include=$(q "$SID.jsonl") --include=$(q "$SID/") --include=$(q "$SID/**") --exclude='*' $HOST:$(q "$RSLUG")/ $(q "$SLUG_DIR")/ && rsync -a --update --include=memory/ --include='memory/**' --exclude='*' $HOST:$(q "$RSLUG")/ $(q "$SLUG_DIR")/"
fi
