#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT/macos/Configuration/version.env"
INFO_PLIST="$ROOT/macos/Configuration/Info.plist"
MANIFEST="$ROOT/update-manifest.json"

read_config_value() {
    local key="$1"
    awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$VERSION_FILE"
}
VERSION="$(read_config_value FLOW_QUOTA_VERSION)"
BUILD_NUMBER="$(read_config_value FLOW_QUOTA_BUILD)"
OUTPUT_DIR=""

usage() {
    cat <<'USAGE'
Usage: scripts/release-macos.sh [options]

Builds arm64 and x86_64 development release DMGs and writes a local release bundle.
The script does not create tags, upload files, sign with Developer ID, or notarize.

Options:
  --version VERSION       Override the version from version.env
  --build BUILD           Override the build number from version.env
  --output-dir PATH       Write release files to an exact directory
USAGE
}

while (($#)); do
    case "$1" in
        --version) VERSION="${2:?missing VERSION}"; shift 2 ;;
        --build) BUILD_NUMBER="${2:?missing BUILD}"; shift 2 ;;
        --output-dir) OUTPUT_DIR="${2:?missing PATH}"; shift 2 ;;
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

INFO_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
INFO_BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw "$INFO_PLIST")"
MANIFEST_VERSION="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])' "$MANIFEST")"
MANIFEST_BUILD="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["build"])' "$MANIFEST")"
if [[ "$INFO_VERSION" != "$VERSION" || "$INFO_BUILD" != "$BUILD_NUMBER" ]]; then
    echo "Info.plist does not match version.env: $INFO_VERSION/$INFO_BUILD vs $VERSION/$BUILD_NUMBER" >&2
    echo "Run scripts/set-version.sh $VERSION $BUILD_NUMBER first." >&2
    exit 1
fi
if [[ "$MANIFEST_VERSION" != "$VERSION" || "$MANIFEST_BUILD" != "$BUILD_NUMBER" ]]; then
    echo "update-manifest.json does not match version.env: $MANIFEST_VERSION/$MANIFEST_BUILD vs $VERSION/$BUILD_NUMBER" >&2
    echo "Run scripts/set-version.sh $VERSION $BUILD_NUMBER first." >&2
    exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$ROOT/.artifacts/releases/FlowQuota-$VERSION-build-$BUILD_NUMBER"
elif [[ "$OUTPUT_DIR" != /* ]]; then
    OUTPUT_DIR="$ROOT/$OUTPUT_DIR"
fi
if [[ -e "$OUTPUT_DIR" ]]; then
    echo "Output directory already exists: $OUTPUT_DIR" >&2
    echo "Choose another --output-dir so an earlier release bundle is not overwritten." >&2
    exit 1
fi
mkdir -p "$OUTPUT_DIR"

ARM64_DMG="$OUTPUT_DIR/FlowQuota-$VERSION-dev-arm64.dmg"
X64_DMG="$OUTPUT_DIR/FlowQuota-$VERSION-dev-x86_64.dmg"
"$ROOT/scripts/build-macos.sh" --release --arm64 --version "$VERSION" --build "$BUILD_NUMBER" \
    --dmg-output "$ARM64_DMG"
"$ROOT/scripts/build-macos.sh" --release --x64 --version "$VERSION" --build "$BUILD_NUMBER" \
    --dmg-output "$X64_DMG"

cp "$MANIFEST" "$OUTPUT_DIR/update-manifest.json"
(
    cd "$OUTPUT_DIR"
    shasum -a 256 "$(basename "$ARM64_DMG")" "$(basename "$X64_DMG")" > SHA256SUMS
)

VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" OUTPUT_DIR="$OUTPUT_DIR" \
MANIFEST="$MANIFEST" /usr/bin/python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path

output = Path(os.environ["OUTPUT_DIR"])
manifest = json.loads(Path(os.environ["MANIFEST"]).read_text(encoding="utf-8"))
assets = []
for path in sorted(output.glob("*.dmg")):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    assets.append({"file": path.name, "sha256": digest})
release = {
    "version": os.environ["VERSION"],
    "build": int(os.environ["BUILD_NUMBER"]),
    "minimumSystemVersion": manifest.get("minimumSystemVersion"),
    "releaseNotesURL": manifest.get("releaseNotesURL"),
    "downloadURL": manifest.get("downloadURL"),
    "assets": assets,
    "signing": "ad-hoc",
    "notarized": False,
}
(output / "release-manifest.json").write_text(
    json.dumps(release, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
PY

cat > "$OUTPUT_DIR/RELEASE-NOTES.md" <<EOF_NOTES
# Flow Quota $VERSION

- Version: $VERSION
- Build: $BUILD_NUMBER
- Minimum macOS: $(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$INFO_PLIST")
- Architectures: arm64, x86_64
- Signing: local ad-hoc development signing
- Notarization: not completed

Assets:

- FlowQuota-$VERSION-dev-arm64.dmg
- FlowQuota-$VERSION-dev-x86_64.dmg

Verify downloads with: shasum -a 256 -c SHA256SUMS.
EOF_NOTES

printf 'Release bundle prepared: %s\n' "$OUTPUT_DIR"
printf '%s\n' 'Upload the two DMGs to a GitHub Release after creating the matching tag.'
