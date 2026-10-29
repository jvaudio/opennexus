#!/bin/zsh
# Live sessions for real (M46): the relay in Docker, then three Macs, a view-only guest and
# a late joiner through the real network code (latency, view only, the join page's view,
# End Session, nothing in the clear on the wire). Then the room's files on the server are
# searched for the same words. Needs Docker; the server listens on 127.0.0.1 only, and it
# goes away at the end.
#
#   scripts/test-collab.sh          run, then stop the server
#   scripts/test-collab.sh --keep   leave it running (stop it with
#                                   docker compose -f server/compose.test.yaml down -v)
set -euo pipefail

ROOT=${0:A:h:h}
COMPOSE=(docker compose -f "$ROOT/server/compose.test.yaml")
keep=0
[[ ${1:-} == --keep ]] && keep=1

command -v docker >/dev/null || { print -u2 "test-collab: needs Docker"; exit 1; }

OUT=$(mktemp -d -t test-collab)
LOG=$OUT/log

# Runs a quiet step; on failure, shows its output's end.
step() {
  "$@" >"$LOG" 2>&1 || { tail -40 "$LOG" >&2; return 1; }
  grep -E 'live edit to two others' "$LOG" || true
  grep -E '✔ Test run|✘ Test run' "$LOG" | tail -1
}

cleanup() {
  rm -rf "$OUT"
  (( keep )) || "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

print "== Starting the server"
"${COMPOSE[@]}" up -d --build --wait --quiet-pull server

print "== Four Macs in a session through the real network code"
step env -C "$ROOT" OPENNEXUS_LIVE_COLLAB=1 OPENNEXUS_LIVE_COLLAB_OUT="$OUT" swift test --filter CollabLive

print "== The room's files on the server: sealed bytes only"
"${COMPOSE[@]}" cp server:/data/rooms "$OUT/rooms" >/dev/null
kept=$(<"$OUT/kept-room")
ended=$(<"$OUT/ended-room")
[[ -s $OUT/rooms/$kept/room.json ]] || { print -u2 "the session's room isn't on disk"; exit 1; }
ls "$OUT/rooms/$kept"
[[ ! -e $OUT/rooms/$ended ]] || { print -u2 "End Session left the room's files"; exit 1; }
while IFS= read -r word; do
  [[ -n $word ]] || continue
  if grep -rqaF -- "$word" "$OUT/rooms"; then
    print -u2 "“$word” is on the server's disk in the clear"
    exit 1
  fi
done <"$OUT/words"
print "no topic text in $(find "$OUT/rooms" -type f | wc -l | tr -d ' ') files; the ended room is gone"
