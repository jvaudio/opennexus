#!/bin/zsh
# Share links for real (M44): MinIO and two OpenNexus Servers (one storing on disk, one in
# MinIO) in Docker; the app's share code makes real links against all three; Playwright
# opens them in Chromium and WebKit on the viewer site. Needs Docker; everything listens on
# 127.0.0.1 only, and it all goes away at the end.
#
#   scripts/test-share.sh          run, then stop the containers
#   scripts/test-share.sh --keep   leave the containers running (stop them with
#                                  docker compose -f server/compose.test.yaml down -v)
set -euo pipefail

ROOT=${0:A:h:h}
COMPOSE=(docker compose -f "$ROOT/server/compose.test.yaml")
LIVE=$ROOT/web/fixtures/share-live
S3=http://127.0.0.1:19000
SIGN=(--fail --silent --show-error --aws-sigv4 "aws:amz:us-east-1:s3" --user onxtest:onxtest-secret-key)
keep=0
[[ ${1:-} == --keep ]] && keep=1

command -v docker >/dev/null || { print -u2 "test-share: needs Docker"; exit 1; }

LOG=$(mktemp -t test-share)

# Runs a quiet step; on failure, shows its output's end.
step() {
  "$@" >"$LOG" 2>&1 || { tail -40 "$LOG" >&2; return 1; }
  grep -E '✔|✘|passed|failed' "$LOG" | tail -2
}

cleanup() {
  rm -rf "$LIVE" "$LOG"
  (( keep )) || "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

print "== Starting MinIO and the servers"
"${COMPOSE[@]}" up -d --build --wait --quiet-pull

print "== Buckets: maps (links in a bucket, readable by anyone) and onx-server (the server's)"
for bucket in maps onx-server; do
  # Made, or there from a --keep run.
  curl "${SIGN[@]}" -X PUT "$S3/$bucket" -o /dev/null 2>/dev/null || curl "${SIGN[@]}" -I "$S3/$bucket" -o /dev/null
done
policy='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":["*"]},"Action":["s3:GetObject"],"Resource":["arn:aws:s3:::maps/opennexus/*"]}]}'
curl "${SIGN[@]}" -X PUT "$S3/maps?policy" -H 'Content-Type: application/json' --data "$policy" -o /dev/null

print "== Server: storing in MinIO"
step env -C "$ROOT/server" \
  OPENNEXUS_TEST_S3_ENDPOINT=$S3 OPENNEXUS_TEST_S3_BUCKET=onx-server \
  OPENNEXUS_TEST_S3_ACCESS_KEY=onxtest OPENNEXUS_TEST_S3_SECRET_KEY=onxtest-secret-key \
  swift test --filter storesInABucket

print "== App: real links against MinIO and both servers"
step env -C "$ROOT" OPENNEXUS_LIVE_SHARE=1 swift test --filter ShareLive
[[ -f $LIVE/manifest.json ]] || { print -u2 "test-share: ShareLive wrote no links"; exit 1; }

print "== Browsers: opening them"
cd "$ROOT/web"
[[ -d node_modules ]] || npm ci --no-audit --no-fund --silent
npm run build --silent -w viewer-app
npx playwright test e2e/share.spec.ts -g "MinIO and the server"
