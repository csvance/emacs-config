#!/usr/bin/env bash
# revise-watch.sh: forward local saves of .jl files to the REPL host as `touch`es there,
# so Revise (inotify on the REPL host) sees edits made over NFS from this host.
#
# Usage: revise-watch.sh HOST LOCAL_TREE [REMOTE_TREE]
#   HOST         ssh destination, e.g. user@host (explicit user, so GSSAPI applies)
#   LOCAL_TREE   the project directory on this host
#   REMOTE_TREE  the same tree's path on HOST (default: LOCAL_TREE, for a shared home)
#
# TOUCH_MODE=atime (default) touches access time only, so editors here see no mtime change.
# TOUCH_MODE=mtime is a plain touch, if access-time-only touches don't trigger Revise.
#
# Started and stopped by revise-sync.el; it can also be run by hand (Ctrl-C to stop).
set -uo pipefail

[ $# -ge 2 ] || { echo "usage: $0 HOST LOCAL_TREE [REMOTE_TREE]" >&2; exit 2; }
REPL_HOST="$1"
LOCAL_TREE="${2%/}"
REMOTE_TREE="${3:-$LOCAL_TREE}"
REMOTE_TREE="${REMOTE_TREE%/}"
TOUCH_MODE="${TOUCH_MODE:-atime}"

command -v inotifywait >/dev/null || { echo "inotifywait not found (install inotify-tools)" >&2; exit 1; }
[ -d "$LOCAL_TREE" ] || { echo "LOCAL_TREE does not exist here: $LOCAL_TREE" >&2; exit 1; }

case "$TOUCH_MODE" in
  atime) TOUCH="touch -c -a" ;;
  mtime) TOUCH="touch -c" ;;
  *) echo "TOUCH_MODE must be atime or mtime" >&2; exit 1 ;;
esac

# On TERM or Ctrl-C, stop the whole process group (inotifywait, ssh), not just this shell.
trap 'trap - TERM INT; kill 0' TERM INT

SSH=(ssh -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 "$REPL_HOST")

# Fail fast on auth or path problems instead of silently touching nothing.
if ! "${SSH[@]}" test -d "'$REMOTE_TREE'"; then
  echo "cannot reach $REPL_HOST, or REMOTE_TREE is not a directory there: $REMOTE_TREE" >&2
  echo "(BatchMode is on: a password prompt shows up here as a failure; check GSSAPI with ssh -v)" >&2
  exit 1
fi

# The remote loop: touch each path, and say what happened. `-c` never creates a missing file.
REMOTE_LOOP="while IFS= read -r f; do
  if [ -e \"\$f\" ]; then $TOUCH -- \"\$f\" && echo \"\$(date +%T) touched \$f\"
  else echo \"\$(date +%T) MISSING on $REPL_HOST: \$f\"; fi
done"

echo "watching $LOCAL_TREE -> $REPL_HOST:$REMOTE_TREE (touch mode: $TOUCH_MODE)"

while true; do
  inotifywait -m -r -q -e close_write,moved_to --format '%w%f' \
      --exclude '(/\.git/|/\.idea/|___jb_(tmp|old)___|~$|/\.#|#$)' "$LOCAL_TREE" \
    | grep --line-buffered '\.jl$' \
    | while IFS= read -r path; do
        # Map this host's prefix to the REPL host's, then forward.
        printf '%s\n' "${REMOTE_TREE}${path#"$LOCAL_TREE"}"
      done \
    | "${SSH[@]}" "$REMOTE_LOOP" &
  wait $!
  echo "$(date +%T) connection or watcher ended; reconnecting in 2s" >&2
  sleep 2
done
