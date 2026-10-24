#!/bin/zsh
# Publishes a release made by App/tools/release.sh (D276): tags the commit it was built
# from, creates the GitHub Release with the DMG and its SHA-256, and then pushes the
# updated appcast.xml, so the update feed never points at a file that isn't there yet.
#
#   App/tools/publish.sh 0.2                     # notes: the default text
#   App/tools/publish.sh 0.2 notes.md            # notes from a Markdown file
#   App/tools/publish.sh 0.3-beta                # a Beta build (release.sh CHANNEL=beta)
#                                                # is published as a pre-release
#
# Needs the gh CLI signed in with push access, and a clean tree apart from appcast.xml.
set -euo pipefail

ROOT=${0:A:h:h:h}
cd "$ROOT"
VERSION=${1:?usage: publish.sh <version> [notes.md]}
NOTES=${2:-}
TAG="v$VERSION"
DMG="dist/OpenNexus-$VERSION.dmg"
REPO=${REPO:-jvaudio/opennexus}

[[ -f "$DMG" && -f "$DMG.sha256" ]] || { print -u2 "publish: $DMG (and .sha256) not found; run release.sh first"; exit 1; }
grep -q "OpenNexus-$VERSION.dmg" appcast.xml || { print -u2 "publish: appcast.xml has no $VERSION; run release.sh first"; exit 1; }
# The feed entry release.sh wrote decides the channel, so the GitHub Release can't
# disagree with it: a Beta build is a pre-release, never the latest download.
FEED_CHANNEL=$(python3 -I - "$VERSION" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
for item in ET.parse("appcast.xml").getroot().iter("item"):
    if item.findtext(ns + "shortVersionString") == sys.argv[1]:
        print(item.findtext(ns + "channel") or "")
        break
PY
)
if [[ -n ${CHANNEL:-} && $CHANNEL != "$FEED_CHANNEL" ]]; then
    print -u2 "publish: CHANNEL=$CHANNEL, but appcast.xml lists $VERSION on ${FEED_CHANNEL:-the default channel}"
    exit 1
fi

other=$(git status --porcelain | grep -v ' appcast.xml$' || true)
[[ -z "$other" ]] || { print -u2 "publish: commit or stash other changes first:\n$other"; exit 1; }
xcrun stapler validate "$DMG" >/dev/null 2>&1 || print -u2 "publish: warning: $DMG isn't notarized and stapled"

BUILT=$(git rev-parse HEAD)
if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    git tag -a "$TAG" "$BUILT" -m "OpenNexus $VERSION"
fi
git push origin "$TAG"

args=(--verify-tag --title "OpenNexus $VERSION")
[[ $FEED_CHANNEL == beta ]] && args+=(--prerelease --latest=false)
if [[ -n "$NOTES" ]]; then
    args+=(--notes-file "$NOTES")
else
    args+=(--notes "OpenNexus $VERSION. Download the DMG, open it, and drag OpenNexus to Applications (macOS 27, Apple silicon). Installed copies with update checks on are offered it automatically.")
fi
gh release create "$TAG" "$DMG" "$DMG.sha256" -R "$REPO" "${args[@]}"

# Only now does the feed point at the new DMG.
git add appcast.xml
git commit -q -m "Update feed: OpenNexus $VERSION"
git push -q origin HEAD
print "Published $TAG: https://github.com/$REPO/releases/tag/$TAG (feed updated)"
