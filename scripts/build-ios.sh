#!/bin/zsh
# Builds the modules the iPad and iPhone app shares with the Mac for the iOS Simulator
# (M47a), so a Mac-only import or API in them fails here rather than in M47b.
#
#   scripts/build-ios.sh
#
# SwiftPM cross-compiles with the simulator SDK from the installed Xcode, into its own
# scratch path so the Mac build isn't touched.
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"

sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
arch=$(uname -m)
targets=(
    NexusCore NexusLayout NexusFormat NexusTheme NexusKeys NexusScene NexusAI
    NexusInterchange NexusSync NexusReplica NexusCanvas
)

for m in $targets; do
    print "build-ios: $m"
    swift build --target "$m" --triple "$arch-apple-ios27.0-simulator" --sdk "$sdk" \
        --scratch-path .build/ios -q
done
print "build-ios: all ${#targets} modules build for the iOS Simulator"
