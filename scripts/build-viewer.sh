#!/bin/zsh
# Builds the interactive viewer (web/viewer-core) and copies it into the Swift resources,
# where interactive HTML exports and viewer copies pick it up (M43).
#
#   scripts/build-viewer.sh           build and copy
#   scripts/build-viewer.sh --check   fail if the copy in Sources/NexusCanvas/Viewer is stale
set -euo pipefail

ROOT=${0:A:h:h}
DEST=$ROOT/Sources/NexusCanvas/Viewer
check=0
[[ ${1:-} == --check ]] && check=1

cd "$ROOT/web"
[[ -d node_modules ]] || npm ci --no-audit --no-fund --silent
npm run build --silent

failed=0
for f in opennexus-viewer.js opennexus-viewer.css; do
  built=viewer-core/dist/$f
  # The script and style sit inline in exported pages: they must never close their element.
  if grep -qiE '</(script|style)' "$built"; then
    print -u2 "build-viewer: $f contains a closing </script> or </style>"
    exit 1
  fi
  if (( check )); then
    if ! cmp -s "$built" "$DEST/$f"; then
      print -u2 "build-viewer: Sources/NexusCanvas/Viewer/$f is stale; run scripts/build-viewer.sh"
      failed=1
    fi
  else
    cp "$built" "$DEST/$f"
  fi
done
exit $failed
