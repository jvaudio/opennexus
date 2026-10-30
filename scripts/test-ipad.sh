#!/bin/zsh
# The iPad against a Mac for real (M47b's A5): MinIO and the relay in Docker; this Mac's
# tests and the iPad simulator's take turns on one folder. A shared library folder and an
# S3 library merge both ways, the iPad joins a session the Mac hosts, and a share link made
# on the iPad opens in Chromium and WebKit. Needs Docker and the iPad Pro 13-inch (M5)
# simulator; everything listens on 127.0.0.1 only, and it all goes away at the end.
#
#   scripts/test-ipad.sh          run, then stop the containers
#   scripts/test-ipad.sh --keep   leave them running (stop them with
#                                 docker compose -f server/compose.test.yaml down -v)
set -euo pipefail

ROOT=${0:A:h:h}
COMPOSE=(docker compose -f "$ROOT/server/compose.test.yaml")
S3=http://127.0.0.1:19000
SIGN=(--fail --silent --show-error --aws-sigv4 "aws:amz:us-east-1:s3" --user onxtest:onxtest-secret-key)
DEVICE=${OPENNEXUS_IPAD_DEVICE:-iPad Pro 13-inch (M5)}
XCODE=(xcodebuild -project "$ROOT/App/OpenNexusiOS.xcodeproj" -scheme "OpenNexus iOS"
  -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath "$ROOT/.build/ipad-dd")
keep=0
[[ ${1:-} == --keep ]] && keep=1

command -v docker >/dev/null || { print -u2 "test-ipad: needs Docker"; exit 1; }

OUT=$(mktemp -d -t test-ipad)
LOG=$OUT/log
HOST=
export OPENNEXUS_IPAD_LIVE=1 OPENNEXUS_IPAD_LIVE_DIR=$OUT
export TEST_RUNNER_OPENNEXUS_IPAD_LIVE=1 TEST_RUNNER_OPENNEXUS_IPAD_LIVE_DIR=$OUT

# Runs a quiet step; on failure, shows its output's end.
step() {
  "$@" >"$LOG" 2>&1 || { tail -40 "$LOG" >&2; return 1; }
  grep -E '✔ Test run|✘ Test run|\*\* TEST' "$LOG" | tail -1 || true  # a build has no summary
}
mac() { step env -C "$ROOT" swift test --filter "IPadLive/$1"; }
ipad() { step "${XCODE[@]}" test-without-building "-only-testing:OpenNexusiOSTests/LiveTests/$1()"; }

cleanup() {
  [[ -n $HOST ]] && kill $HOST 2>/dev/null || true
  rm -rf "$OUT" "$ROOT/web/fixtures/share-ipad"
  (( keep )) || "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

print "== Starting MinIO and the relay"
"${COMPOSE[@]}" up -d --build --wait --quiet-pull minio server

print "== Buckets: sync (private) and maps (links, readable by anyone)"
for bucket in sync maps; do
  curl "${SIGN[@]}" -X PUT "$S3/$bucket" -o /dev/null 2>/dev/null || curl "${SIGN[@]}" -I "$S3/$bucket" -o /dev/null
done
policy='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":["*"]},"Action":["s3:GetObject"],"Resource":["arn:aws:s3:::maps/opennexus/*"]}]}'
curl "${SIGN[@]}" -X PUT "$S3/maps?policy" -H 'Content-Type: application/json' --data "$policy" -o /dev/null

print "== Building the Mac's tests and the iPad's"
step env -C "$ROOT" swift build --build-tests
step "${XCODE[@]}" build-for-testing

print "== Mac: the folder's map, the Mac's save of it, and the S3 library pushed"
mac macPrepares
print "== iPad: the Mac's save lands while the map is open with an edit"
ipad iPadMergesTheMacsSave
print "== iPad: joins the S3 library, edits and pushes"
ipad iPadSyncsAnS3Library
print "== Mac: merges the iPad's save and its push with edits of its own"
mac macMergesTheIPad
print "== iPad: pulls the merge"
ipad iPadSeesTheMerge

print "== A session: the Mac hosts, the iPad joins"
env -C "$ROOT" swift test --filter IPadLive/macHostsASession >"$OUT/host.log" 2>&1 &
HOST=$!
ipad iPadJoinsAMacsSession
wait $HOST || { tail -40 "$OUT/host.log" >&2; exit 1; }
HOST=
grep -E '✔ Test run|✘ Test run' "$OUT/host.log" | tail -1
cmp -s "$OUT/mac-canonical" "$OUT/ipad-canonical" || { print -u2 "the iPad's copy isn't the Mac's"; exit 1; }
print "the Mac's copy and the iPad's are the same bytes"

print "== iPad: a share link to MinIO"
ipad iPadMakesAShareLink
[[ -f $ROOT/web/fixtures/share-ipad/manifest.json ]] || { print -u2 "test-ipad: the iPad wrote no link"; exit 1; }

print "== Browsers: opening it"
cd "$ROOT/web"
[[ -d node_modules ]] || npm ci --no-audit --no-fund --silent
npm run build --silent -w viewer-app
npx playwright test e2e/share.spec.ts -g "made on the iPad"
