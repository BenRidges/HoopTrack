#!/bin/bash
# Fails if any class's deinit goes through Swift's back-deployed
# "deinit on the main actor" shim. Built for iOS 17 and run on iOS 26, that
# shim frees a pointer malloc never handed out and aborts the app whenever
# such an object is released (seen with TrainViewModel and AppServices).
# A class gets the shim when it is main-actor isolated (the project default)
# and has no deinit of its own; the fix is an explicit `deinit {}`.
#
# Usage: check-isolated-deinit.sh [path/to/HoopTrack.debug.dylib]
# Without an argument it uses the newest Debug simulator build in DerivedData.
set -euo pipefail
DYLIB=${1:-$(ls -t ~/Library/Developer/Xcode/DerivedData/HoopTrack-*/Build/Products/Debug-iphonesimulator/HoopTrack.app/HoopTrack.debug.dylib | head -1)}
# Xcode's generated ResourceBundleClass is never instantiated, so it can't crash.
CALLERS=$(xcrun objdump -d --no-show-raw-insn "$DYLIB" \
  | awk '/^[0-9a-f]+ <.*>:/ { fn = $2 } /bl.*deinitOnExecutorMainActorBackDeploy/ { print fn }' \
  | sort -u | xcrun swift-demangle | grep -v ResourceBundleClass || true)
if [ -n "$CALLERS" ]; then
  echo "These classes need an explicit 'deinit {}' (see \"Explicit deinit\" in HoopTrack/CLAUDE.md):"
  echo "$CALLERS" | sed -E 's/^<HoopTrack\.(.*)\.__deallocating_deinit>:$/  \1/'
  exit 1
fi
echo "No class deinit goes through the back-deploy shim."
