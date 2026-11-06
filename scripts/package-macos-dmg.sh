#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$ROOT/.artifacts/cache/clang"
[[ $# == 2 ]] || { echo 'Usage: package-macos-dmg.sh APP OUTPUT.dmg' >&2; exit 2; }
APP="$1"
OUTPUT="$2"
[[ -d "$APP" && "$OUTPUT" = /* && ! -e "$OUTPUT" ]] || {
    echo 'Require an existing app and a new absolute DMG output path.' >&2; exit 2;
}
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
mkdir -p "$ROOT/.artifacts" "$(dirname "$OUTPUT")"
# Keep the Applications symlink outside the source workspace so editor indexers
# cannot traverse installed apps, even while packaging or after interruption.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/flow-quota-dmg.XXXXXX")"
# Keep the final volume name from the start: Finder background aliases do not
# reliably survive renaming. /Volumes also keeps source paths out of metadata.
VOLUME="Flow Quota $VERSION"
MOUNT="/Volumes/$VOLUME"
[[ ! -e "$MOUNT" ]] || {
    echo "Eject the existing $MOUNT disk image before packaging this version." >&2
    rmdir "$WORK"
    exit 1
}
MOUNTED=false
cleanup() {
    if $MOUNTED; then
        if ! /usr/sbin/diskutil eject "$MOUNT"; then
            echo "Could not eject temporary DMG; preserved workspace: $WORK" >&2
            return 1
        fi
    fi
    # Never remove a mounted filesystem; only this invocation's temporary files.
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$WORK/stage/.background"
ditto "$APP" "$WORK/stage/Flow Quota.app"
ln -s /Applications "$WORK/stage/Applications"
cp "$ROOT/macos/Configuration/INSTALL.txt" "$WORK/stage/安装说明.txt"
xcrun swiftc -parse-as-library -swift-version 6 "$ROOT/scripts/GenerateDMGBackground.swift" \
    -o "$WORK/generate-background"
"$WORK/generate-background" "$WORK/stage/.background/installer.tiff"
SYSTEM_VERSION="$(sw_vers -productVersion)"
if [[ "${SYSTEM_VERSION%%.*}" -ge 27 ]]; then
    # macOS 27 documents RAW for writable images and create-from for conversion.
    /usr/sbin/diskutil image create from --volumeName "$VOLUME" \
        --format RAW "$WORK/stage" "$WORK/layout.dmg"
else
    /usr/bin/hdiutil create -volname "$VOLUME" -srcfolder "$WORK/stage" \
        -format UDRW "$WORK/layout.dmg"
fi
if [[ "${SYSTEM_VERSION%%.*}" -ge 27 ]]; then
    /usr/sbin/diskutil image attach --mountPoint "$MOUNT" "$WORK/layout.dmg"
else
    /usr/bin/hdiutil attach "$WORK/layout.dmg" -mountpoint "$MOUNT" -noautoopen
fi
MOUNTED=true
/usr/bin/osascript "$ROOT/scripts/layout-macos-dmg.applescript" "$MOUNT"
# Finder writes metadata asynchronously after the last window closes.
for attempt in 1 2 3 4 5; do
    [[ ! -s "$MOUNT/.DS_Store" ]] || break
    sleep 1
done
[[ -s "$MOUNT/.DS_Store" ]] || { echo 'Finder did not write DMG layout metadata.' >&2; exit 1; }
/usr/sbin/diskutil eject "$MOUNT"
MOUNTED=false
if [[ "${SYSTEM_VERSION%%.*}" -ge 27 ]]; then
    /usr/sbin/diskutil image create from --format UDZO "$WORK/layout.dmg" "$OUTPUT"
else
    /usr/bin/hdiutil convert "$WORK/layout.dmg" -format UDZO -o "$OUTPUT"
fi
shasum -a 256 "$OUTPUT"
echo "DMG: $OUTPUT (ad-hoc signed, not notarized)"
