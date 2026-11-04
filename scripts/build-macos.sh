#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$ROOT/.artifacts/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.artifacts/cache/swift"
PACKAGE_OPTIONS=(--package-path "$ROOT/macos"
    --cache-path "$ROOT/.artifacts/swiftpm/cache"
    --config-path "$ROOT/.artifacts/swiftpm/config"
    --security-path "$ROOT/.artifacts/swiftpm/security")
CONFIG=debug
ARCH="$(uname -m)"
DMG=false
for ARG in "$@"; do
    case "$ARG" in
        --release) CONFIG=release ;;
        --x64) ARCH=x86_64 ;;
        --arm64) ARCH=arm64 ;;
        --dmg) DMG=true ;;
        *) echo "Unknown option: $ARG" >&2; exit 2 ;;
    esac
done
SCRATCH="$ROOT/.artifacts/swift-$ARCH"
xcrun swift build "${PACKAGE_OPTIONS[@]}" --scratch-path "$SCRATCH" \
    --disable-sandbox --configuration "$CONFIG" --arch "$ARCH" --product FlowQuota
xcrun swift build "${PACKAGE_OPTIONS[@]}" --scratch-path "$SCRATCH" \
    --disable-sandbox --configuration "$CONFIG" --arch "$ARCH" --product FlowQuotaAgent
BIN="$(xcrun swift build "${PACKAGE_OPTIONS[@]}" --scratch-path "$SCRATCH" \
    --disable-sandbox --configuration "$CONFIG" --arch "$ARCH" --show-bin-path)"
APP="$ROOT/.artifacts/$ARCH/Flow Quota.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchAgents"
cp "$BIN/FlowQuota" "$APP/Contents/MacOS/FlowQuota"
cp "$BIN/FlowQuotaAgent" "$APP/Contents/MacOS/FlowQuotaAgent"
cp "$ROOT/macos/Configuration/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/macos/Configuration/local.flowquota.agent.plist" "$APP/Contents/Library/LaunchAgents/"
# Local ad-hoc identity enables exact-binary XPC verification; it grants no
# NetworkExtension entitlement and is not Developer ID signing/notarization.
codesign --force --sign - --identifier local.flowquota.agent "$APP/Contents/MacOS/FlowQuotaAgent"
codesign --force --sign - --identifier local.flowquota.app "$APP"
codesign --verify --strict "$APP"
echo "Built: $APP"
if $DMG; then
    STAGE="$(mktemp -d "$ROOT/.artifacts/dmg-stage.XXXXXX")"
    ditto "$APP" "$STAGE/Flow Quota.app"
    ln -s /Applications "$STAGE/Applications"
    OUTPUT="$ROOT/.artifacts/FlowQuota-0.1.0-dev-$ARCH.dmg"
    SYSTEM_VERSION="$(sw_vers -productVersion)"
    if [[ "${SYSTEM_VERSION%%.*}" -ge 27 ]]; then
        # macOS 27's official CLI replaces deprecated hdiutil create.
        # Keep an earlier generated artifact rather than overwrite it implicitly.
        if [[ -e "$OUTPUT" ]]; then
            OUTPUT="$ROOT/.artifacts/FlowQuota-0.1.0-dev-$ARCH-$(date +%Y%m%d-%H%M%S).dmg"
        fi
        diskutil image create from --volumeName 'Flow Quota Development' \
            --format UDZO "$STAGE" "$OUTPUT"
    else
        hdiutil create -volname 'Flow Quota Development' -srcfolder "$STAGE" \
            -ov -format UDZO "$OUTPUT"
    fi
    shasum -a 256 "$OUTPUT"
    echo "Development DMG only: no notarization or active traffic protection."
fi
