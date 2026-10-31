#!/bin/zsh
# Builds MathJax for the app's JavaScriptCore context (web/math) and copies it into the
# Swift resources, where NexusScene's MathEngine loads it (M48).
#
#   scripts/build-math.sh           build and copy
#   scripts/build-math.sh --check   fail if the copy in Sources/NexusScene/MathJax is stale
set -euo pipefail

ROOT=${0:A:h:h}
DEST=$ROOT/Sources/NexusScene/MathJax
check=0
[[ ${1:-} == --check ]] && check=1

cd "$ROOT/web"
[[ -d node_modules ]] || npm ci --no-audit --no-fund --silent
npm run build -w math --silent

built=math/dist/nexus-math.js
if (( check )); then
  if ! cmp -s "$built" "$DEST/nexus-math.js"; then
    print -u2 "build-math: Sources/NexusScene/MathJax/nexus-math.js is stale; run scripts/build-math.sh"
    exit 1
  fi
else
  cp "$built" "$DEST/nexus-math.js"
  cp node_modules/@mathjax/src/LICENSE "$DEST/LICENSE"
fi
