#!/bin/zsh
# Builds the Obsidian plugin's release (M49): main.js, manifest.json and styles.css in
# dist/obsidian/<version>/, with a zip that unpacks into a vault's plugins folder.
#
#   scripts/release-obsidian.sh                    build and check the release
#   scripts/release-obsidian.sh --install <vault>  also install it into a vault, by hand
#   scripts/release-obsidian.sh --publish          also mirror and release it on GitHub
#
# It stops unless manifest.json, versions.json and package.json agree on the version and
# main.js plus styles.css is at most 300 KB. --install copies the three files into
# <vault>/.obsidian/plugins/opennexus/ and turns the plugin on, as a reader would by hand.
# --publish mirrors web/obsidian into jvaudio/opennexus-obsidian (Obsidian's directory
# wants the manifest at a repository's root, D451), tags the version and creates the
# release; it stops with instructions when that repository doesn't exist yet.
set -euo pipefail

ROOT=${0:A:h:h}
PLUGIN=$ROOT/web/obsidian
MIRROR=jvaudio/opennexus-obsidian
LIMIT=$((300 * 1024))

install_to=""
publish=false
while (( $# > 0 )); do
    case $1 in
        --install) install_to=${2:?"--install needs a vault folder"}; shift 2 ;;
        --publish) publish=true; shift ;;
        *) print -u2 "usage: scripts/release-obsidian.sh [--install <vault>] [--publish]"; exit 64 ;;
    esac
done

json() { node -p "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'))$2" "$1"; }

version=$(json "$PLUGIN/manifest.json" .version)
min_app=$(json "$PLUGIN/manifest.json" .minAppVersion)
package_version=$(json "$PLUGIN/package.json" .version)
listed=$(json "$PLUGIN/versions.json" "[\"$version\"] ?? ''")
if [[ $package_version != "$version" ]]; then
    print -u2 "release-obsidian: package.json says $package_version, manifest.json $version"
    exit 1
fi
if [[ $listed != "$min_app" ]]; then
    print -u2 "release-obsidian: versions.json needs \"$version\": \"$min_app\" (it has \"$listed\")"
    exit 1
fi

print "release-obsidian: building $version"
(cd "$ROOT/web" && npm run build -w obsidian --silent)

built=$PLUGIN/dist
bytes=$(( $(stat -f %z "$built/main.js") + $(stat -f %z "$built/styles.css") ))
if (( bytes > LIMIT )); then
    print -u2 "release-obsidian: main.js and styles.css are $bytes bytes, over $LIMIT"
    exit 1
fi

out=$ROOT/dist/obsidian/$version
rm -rf "$out"
mkdir -p "$out/opennexus"
cp "$built/main.js" "$built/styles.css" "$PLUGIN/manifest.json" "$out/opennexus/"
(cd "$out" && zip -qrX "opennexus-$version.zip" opennexus && mv opennexus/* . && rmdir opennexus)
print "release-obsidian: $out ($bytes bytes of script and style)"

if [[ -n $install_to ]]; then
    vault=${install_to:A}
    [[ -d $vault ]] || { print -u2 "release-obsidian: $vault isn't a folder"; exit 1; }
    plugins=$vault/.obsidian/plugins/opennexus
    mkdir -p "$plugins"
    cp "$out/main.js" "$out/manifest.json" "$out/styles.css" "$plugins/"
    node -e '
        const fs = require("fs");
        const file = process.argv[1];
        let on = [];
        try { on = JSON.parse(fs.readFileSync(file, "utf8")); } catch {}
        if (!on.includes("opennexus")) on.push("opennexus");
        fs.writeFileSync(file, JSON.stringify(on, null, 2));
    ' "$vault/.obsidian/community-plugins.json"
    print "release-obsidian: installed in $plugins"
fi

if $publish; then
    if ! gh repo view "$MIRROR" >/dev/null 2>&1; then
        print -u2 "release-obsidian: $MIRROR doesn't exist yet. Create it (public, empty), then run --publish again:"
        print -u2 "  gh repo create $MIRROR --public --description \"OpenNexus maps in Obsidian\""
        exit 1
    fi
    if gh release view "$version" --repo "$MIRROR" >/dev/null 2>&1; then
        print -u2 "release-obsidian: $MIRROR already has a $version release; raise the version first"
        exit 1
    fi
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    gh repo clone "$MIRROR" "$work/mirror" -- --quiet
    rsync -a --delete --exclude .git --exclude node_modules --exclude dist --exclude test-vault \
        "$PLUGIN/" "$work/mirror/"
    cp "$ROOT/LICENSE" "$work/mirror/LICENSE"
    git -C "$work/mirror" add -A
    git -C "$work/mirror" commit -qm "OpenNexus for Obsidian $version" || true
    git -C "$work/mirror" tag "$version"
    git -C "$work/mirror" push -q origin HEAD "$version"
    gh release create "$version" --repo "$MIRROR" --title "$version" --notes "OpenNexus for Obsidian $version" \
        "$out/main.js" "$out/manifest.json" "$out/styles.css"
    print "release-obsidian: released $version on $MIRROR"
fi
