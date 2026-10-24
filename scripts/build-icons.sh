#!/bin/zsh
# Builds the .icns files the app bundle carries from the brand kit's iconsets (brand/macos),
# so the step is repeatable after the kit is regenerated (brand/BRAND.md §7). The app icon
# itself comes from the asset catalog (App/OpenNexus/Assets.xcassets/AppIcon.appiconset).
#
#   scripts/build-icons.sh          # writes App/OpenNexus/NexusDocument.icns
#   scripts/build-icons.sh --check  # fails if the committed .icns is out of date
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"
OUT=App/OpenNexus/NexusDocument.icns
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

iconutil -c icns brand/macos/NexusDocument.iconset -o "$TMP/NexusDocument.icns"
if [[ ${1:-} == --check ]]; then
    # Compare the decoded images, not the bytes: iconutil's container isn't byte-stable.
    iconutil -c iconset "$TMP/NexusDocument.icns" -o "$TMP/new.iconset"
    iconutil -c iconset "$OUT" -o "$TMP/old.iconset"
    diff -rq "$TMP/new.iconset" "$TMP/old.iconset" >/dev/null || {
        print -u2 "build-icons: $OUT is out of date; run scripts/build-icons.sh"
        exit 1
    }
    print "build-icons: $OUT is up to date"
else
    cp "$TMP/NexusDocument.icns" "$OUT"
    print "build-icons: wrote $OUT"
fi
