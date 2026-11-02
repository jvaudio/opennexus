#!/bin/zsh
# Sync for real (M45): MinIO in Docker; the property test (50 seeds) and the upload and
# speed checks through the real network service, then the longer property run in memory.
# Needs Docker; MinIO listens on 127.0.0.1 only, and it goes away at the end.
#
#   scripts/test-sync.sh          run, then stop MinIO
#   scripts/test-sync.sh --keep   leave it running (stop it with
#                                 docker compose -f server/compose.test.yaml down -v)
set -euo pipefail

ROOT=${0:A:h:h}
COMPOSE=(docker compose -f "$ROOT/server/compose.test.yaml")
S3=http://127.0.0.1:19000
SIGN=(--fail --silent --show-error --aws-sigv4 "aws:amz:us-east-1:s3" --user onxtest:onxtest-secret-key)
keep=0
[[ ${1:-} == --keep ]] && keep=1

command -v docker >/dev/null || { print -u2 "test-sync: needs Docker"; exit 1; }

LOG=$(mktemp -t test-sync)

# Runs a quiet step; on failure, shows its output's end.
step() {
  "$@" >"$LOG" 2>&1 || { tail -40 "$LOG" >&2; return 1; }
  grep -E 'pushed in' "$LOG" || true
  grep -E '✔ Test run|✘ Test run' "$LOG" | tail -1
}

cleanup() {
  rm -f "$LOG"
  (( keep )) || "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

print "== Starting MinIO"
"${COMPOSE[@]}" up -d --build --wait --quiet-pull minio

print "== Bucket: sync (private)"
curl "${SIGN[@]}" -X PUT "$S3/sync" -o /dev/null 2>/dev/null || curl "${SIGN[@]}" -I "$S3/sync" -o /dev/null

print "== Sync against MinIO: conditional writes, 50 seeds, uploads and speed"
step env -C "$ROOT" OPENNEXUS_LIVE_SYNC=1 swift test --filter SyncLiveTests

print "== The property test, longer: 500 seeds of 80 steps, in memory"
step env -C "$ROOT" SYNC_SOAK=1 swift test --filter 'NexusSyncTests/soak'
