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
VERSION_FILE="$ROOT/macos/Configuration/version.env"
CONFIG=debug
ARCH="$(uname -m)"
DMG=false
DMG_OUTPUT=""

read_config_value() {
    local key="$1"
    awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$VERSION_FILE"
}
VERSION="$(read_config_value FLOW_QUOTA_VERSION)"
BUILD_NUMBER="$(read_config_value FLOW_QUOTA_BUILD)"

usage() {
    cat <<'USAGE'
Usage: scripts/build-macos.sh [options]

Options:
  --debug                 Build a debug app (default)
  --release               Build an optimized app
  --arm64                 Build for Apple Silicon
  --x64                   Build for Intel
  --version VERSION       Override the version from version.env
  --build BUILD           Override the build number from version.env
  --dmg                   Create a development DMG
  --dmg-output PATH       Write the DMG to an exact path; implies --dmg
USAGE
}

while (($#)); do
    case "$1" in
        --debug) CONFIG=debug; shift ;;
        --release) CONFIG=release; shift ;;
        --arm64) ARCH=arm64; shift ;;
        --x64) ARCH=x86_64; shift ;;
        --version) VERSION="${2:?missing VERSION}"; shift 2 ;;
        --build) BUILD_NUMBER="${2:?missing BUILD}"; shift 2 ;;
        --dmg) DMG=true; shift ;;
        --dmg-output) DMG=true; DMG_OUTPUT="${2:?missing PATH}"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version must use MAJOR.MINOR.PATCH: $VERSION" >&2
    exit 2
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "Build must be a positive integer: $BUILD_NUMBER" >&2
    exit 2
fi

SCRATCH="$ROOT/.artifacts/swift-$ARCH"
xcrun swift build "${PACKAGE_OPTIONS[@]}" --scratch-path "$SCRATCH" \
    --disable-sandbox --configuration "$CONFIG" --arch "$ARCH" --product FlowQuota
xcrun swift build "${PACKAGE_OPTIONS[@]}" --scratch-path "$SCRATCH" \
    --disable-sandbox --configuration "$CONFIG" --arch "$ARCH" --product FlowQuotaAgent
BIN="$(xcrun swift build "${PACKAGE_OPTIONS[@]}" --scratch-path "$SCRATCH" \
    --disable-sandbox --configuration "$CONFIG" --arch "$ARCH" --show-bin-path)"
APP="$ROOT/.artifacts/$ARCH/Flow Quota.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchAgents" "$APP/Contents/Resources"
cp "$BIN/FlowQuota" "$APP/Contents/MacOS/FlowQuota"
cp "$BIN/FlowQuotaAgent" "$APP/Contents/MacOS/FlowQuotaAgent"
if [[ "$CONFIG" == release ]]; then
    # Apple's strip(1): remove debug and local symbols before signing public binaries.
    xcrun strip -S -x "$APP/Contents/MacOS/FlowQuota" "$APP/Contents/MacOS/FlowQuotaAgent"
fi
cp "$ROOT/macos/Configuration/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
cp "$ROOT/assets/brand/FlowQuota.icns" "$APP/Contents/Resources/FlowQuota.icns"
cp "$ROOT/macos/Configuration/local.flowquota.agent.plist" "$APP/Contents/Library/LaunchAgents/"
# Local ad-hoc identity enables exact-binary XPC verification; it grants no
# NetworkExtension entitlement and is not Developer ID signing/notarization.
codesign --force --sign - --identifier local.flowquota.agent "$APP/Contents/MacOS/FlowQuotaAgent"
codesign --force --sign - --identifier local.flowquota.app "$APP"
codesign --verify --strict "$APP/Contents/MacOS/FlowQuotaAgent"
codesign --verify --strict "$APP"
if [[ "$CONFIG" == release ]]; then
    /usr/bin/python3 "$ROOT/scripts/verify_macos_app.py" --app "$APP" --arch "$ARCH" \
        --version "$VERSION" --build "$BUILD_NUMBER"
fi
echo "Built: $APP (version $VERSION, build $BUILD_NUMBER)"

if $DMG; then
    STAGE="$(mktemp -d "$ROOT/.artifacts/dmg-stage.XXXXXX")"
    # Only this invocation's temporary staging directory is removed.
    trap 'rm -rf "$STAGE"' EXIT
    ditto "$APP" "$STAGE/Flow Quota.app"
    ln -s /Applications "$STAGE/Applications"
    cp "$ROOT/macos/Configuration/INSTALL.txt" "$STAGE/安装说明.txt"
    if [[ -n "$DMG_OUTPUT" ]]; then
        OUTPUT="$DMG_OUTPUT"
        [[ "$OUTPUT" = /* ]] || OUTPUT="$ROOT/$OUTPUT"
    else
        OUTPUT="$ROOT/.artifacts/FlowQuota-$VERSION-dev-$ARCH.dmg"
        if [[ -e "$OUTPUT" ]]; then
            OUTPUT="$ROOT/.artifacts/FlowQuota-$VERSION-dev-$ARCH-$(date +%Y%m%d-%H%M%S).dmg"
        fi
    fi
    mkdir -p "$(dirname "$OUTPUT")"
    SYSTEM_VERSION="$(sw_vers -productVersion)"
    if [[ "${SYSTEM_VERSION%%.*}" -ge 27 ]]; then
        # macOS 27's official CLI replaces deprecated hdiutil create.
        diskutil image create from --volumeName "Flow Quota $VERSION Development" \
            --format UDZO "$STAGE" "$OUTPUT"
    else
        hdiutil create -volname "Flow Quota $VERSION Development" -srcfolder "$STAGE" \
            -ov -format UDZO "$OUTPUT"
    fi
    shasum -a 256 "$OUTPUT"
    echo "Development DMG only: no notarization or active traffic protection."
fi
