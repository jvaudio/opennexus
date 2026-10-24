#!/bin/zsh
# Builds a release of OpenNexus for direct download: a Release archive signed with your
# Developer ID, checked, and packed in a DMG (D273). Notarizes and staples the app and the
# DMG when a notarytool keychain profile exists; without one, the DMG is signed but
# Gatekeeper will ask before the first launch on another Mac. Then signs the DMG for
# Sparkle and adds it to appcast.xml, the update feed (D276); App/tools/publish.sh puts
# it on GitHub.
#
#   App/tools/release.sh                 # version from the project, build number from Git
#   VERSION=0.2 App/tools/release.sh     # or name the version
#   CHANNEL=beta App/tools/release.sh    # offered only to Settings › Updates › Beta
#   NOTARY_PROFILE=other App/tools/release.sh
#   NOTARIZE=0 BUILD=500 FEED=dist/test-appcast.xml URL_PREFIX=http://127.0.0.1:8765/ \
#       App/tools/release.sh             # a local test build and feed (not for release)
#
# Update signing uses the EdDSA key made by Sparkle's generate_keys --account opennexus
# (in the login keychain; keep a backup: generate_keys --account opennexus -x <file>).
#
# One-time notarization setup (Apple ID, team ID and an app-specific password from
# account.apple.com):
#
#   xcrun notarytool store-credentials opennexus --apple-id <you@example.com> --team-id <TEAMID>
#
# Needs: Xcode, a "Developer ID Application" certificate in the login keychain, and
# App/Config/Signing.local.xcconfig naming DEVELOPMENT_TEAM (see Base.xcconfig).
# Output goes to dist/ (not in Git).
set -euo pipefail

ROOT=${0:A:h:h:h}
cd "$ROOT"

NOTARY_PROFILE=${NOTARY_PROFILE:-opennexus}
TEAM=$(sed -n 's/^ *DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' App/Config/Signing.local.xcconfig 2>/dev/null | tail -1)
if [[ -z "$TEAM" ]]; then
    print -u2 "release: App/Config/Signing.local.xcconfig must name DEVELOPMENT_TEAM (see App/Config/Base.xcconfig)"
    exit 1
fi
IDENTITY="Developer ID Application"
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY: .*($TEAM)"; then
    print -u2 "release: no \"$IDENTITY\" certificate for team $TEAM in the keychain"
    exit 1
fi
VERSION=${VERSION:-$(sed -n 's/.*"MARKETING_VERSION": "\([^"]*\)".*/\1/p' App/tools/make_project.py | head -1)}
BUILD=${BUILD:-$(git rev-list --count HEAD)}
CHANNEL=${CHANNEL:-}
FEED=${FEED:-$ROOT/appcast.xml}
URL_PREFIX=${URL_PREFIX:-https://github.com/jvaudio/opennexus/releases/download/v$VERSION/}
SPARKLE_ACCOUNT=${SPARKLE_ACCOUNT:-opennexus}
COMMIT=$(git rev-parse --short HEAD)
if [[ -n "$(git status --porcelain)" ]]; then
    print -u2 "release: warning: the working tree has uncommitted changes; building them anyway"
fi

DIST="$ROOT/dist"
WORK="$DIST/work-$VERSION-$BUILD"
ARCHIVE="$WORK/OpenNexus.xcarchive"
DMG="$DIST/OpenNexus-$VERSION.dmg"
rm -rf "$WORK" "$DMG"
mkdir -p "$WORK"

step() { print "\n==> $*" }

step "Archiving OpenNexus $VERSION ($BUILD, $COMMIT) signed by team $TEAM"
xcodebuild archive \
    -project App/OpenNexus.xcodeproj -scheme OpenNexus -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
    -derivedDataPath "$WORK/DerivedData" \
    DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    | grep -E "error:|warning: .*sign|\*\* ARCHIVE" || true
APP="$ARCHIVE/Products/Applications/OpenNexus.app"
[[ -d "$APP" ]] || { print -u2 "release: the archive has no OpenNexus.app"; exit 1; }
SPARKLE="$WORK/DerivedData/SourcePackages"
SPARKLE_BIN="$SPARKLE/artifacts/sparkle/Sparkle/bin"
DOWNLOADER_ENTITLEMENTS="$SPARKLE/checkouts/Sparkle/Downloader/Downloader.entitlements"
[[ -x "$SPARKLE_BIN/sign_update" && -f "$DOWNLOADER_ENTITLEMENTS" ]] || {
    print -u2 "release: Sparkle's tools aren't in $SPARKLE"
    exit 1
}

# Xcode signs Sparkle.framework but not the services and helpers inside it, which ship
# signed ad hoc. Sign each with the Developer ID, in Sparkle's order and without --deep:
# the Downloader with its sandbox and network-client entitlements (it does the fetching;
# the app has no network entitlement), then the framework, then the app around them.
step "Signing Sparkle's services"
FW="$APP/Contents/Frameworks/Sparkle.framework"
sign() { codesign -f -s "$IDENTITY" -o runtime --timestamp "$@" }
sign --entitlements "$DOWNLOADER_ENTITLEMENTS" "$FW/Versions/B/XPCServices/Downloader.xpc"
sign "$FW/Versions/B/XPCServices/Installer.xpc"
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW"
sign --preserve-metadata=entitlements,requirements,flags "$APP"

step "Checking signatures"
codesign --verify --deep --strict --verbose=1 "$APP"
for code in "$APP" "$APP"/Contents/PlugIns/*.appex "$APP/Contents/Helpers/nexus" "$FW" \
    "$FW"/Versions/B/XPCServices/*.xpc "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app"; do
    info=$(codesign -dvv "$code" 2>&1)
    [[ $info == *"Authority=$IDENTITY"* ]] || { print -u2 "release: $code isn't signed with $IDENTITY"; exit 1; }
    [[ $info == *flags=*runtime* ]] || { print -u2 "release: $code lacks the hardened runtime"; exit 1; }
    [[ $info == *Timestamp=* ]] || { print -u2 "release: $code has no secure timestamp"; exit 1; }
    if [[ $(codesign -d --entitlements - --xml "$code" 2>/dev/null) == *get-task-allow* ]]; then
        print -u2 "release: $code carries the get-task-allow debugging entitlement"
        exit 1
    fi
    print "  ok  ${code#$ARCHIVE/Products/Applications/}"
done
[[ $(codesign -d --entitlements - --xml "$FW/Versions/B/XPCServices/Downloader.xpc" 2>/dev/null) == *network.client* ]] || {
    print -u2 "release: Sparkle's Downloader service lacks the network-client entitlement"
    exit 1
}
[[ $(codesign -d --entitlements - --xml "$APP" 2>/dev/null) != *com.apple.security.network* ]] || {
    print -u2 "release: the app itself must not have a network entitlement (D275)"
    exit 1
}

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m
}
if [[ ${NOTARIZE:-} == 0 ]]; then
    NOTARIZE=0
    NOTARIZE_SKIPPED=1
elif xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    NOTARIZE=1
else
    NOTARIZE=0
fi

if (( NOTARIZE )); then
    step "Notarizing the app (profile $NOTARY_PROFILE)"
    ditto -c -k --keepParent "$APP" "$WORK/OpenNexus.zip"
    notarize "$WORK/OpenNexus.zip"
    xcrun stapler staple "$APP"
fi

step "Making $DMG:t"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/OpenNexus.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "OpenNexus $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --sign "$IDENTITY: " --timestamp "$DMG" 2>/dev/null || codesign --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --verbose=1 "$DMG"

if (( NOTARIZE )); then
    step "Notarizing the DMG"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    step "Gatekeeper"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    spctl --assess --type execute --verbose=2 "$APP"
fi

step "Adding $VERSION ($BUILD) to the update feed"
# sign_update prints: sparkle:edSignature="…" length="…"
SIGNED=$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$DMG")
python3 "$ROOT/App/tools/appcast.py" --feed "$FEED" --version "$VERSION" --build "$BUILD" \
    --url "$URL_PREFIX$DMG:t" --signed "$SIGNED" ${CHANNEL:+--channel "$CHANNEL"} \
    --notes-link "https://github.com/jvaudio/opennexus/releases/tag/v$VERSION"

(cd "$DIST" && shasum -a 256 "$DMG:t" | tee "$DMG:t.sha256")
step "Done: $DMG"
if (( NOTARIZE )); then
    print "Notarized and stapled: it opens on any Mac running macOS 27."
else
    if [[ ${NOTARIZE_SKIPPED:-} == 1 ]]; then
        print "Signed with your Developer ID; notarization skipped (NOTARIZE=0): a test build."
    else
        print "Signed with your Developer ID but not notarized: no notarytool profile \"$NOTARY_PROFILE\"."
    fi
    print "On another Mac, the first launch needs Control-click › Open, or System Settings ›"
    print "Privacy & Security › Open Anyway. To notarize, see the setup at the top of this script."
fi
print "Feed updated: $FEED. Publish with: App/tools/publish.sh $VERSION"
