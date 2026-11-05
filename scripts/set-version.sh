#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT/macos/Configuration/version.env"
INFO_PLIST="$ROOT/macos/Configuration/Info.plist"
MANIFEST="$ROOT/update-manifest.json"

usage() {
    cat <<'USAGE'
Usage: scripts/set-version.sh VERSION BUILD [--release-url URL] [--download-url URL] [--notes-url URL]

Updates the canonical version, app Info.plist and update manifest.
USAGE
}

if [[ $# -eq 1 && ( "$1" == "--help" || "$1" == "-h" ) ]]; then
    usage
    exit 0
fi
if [[ $# -lt 2 ]]; then
    usage >&2
    exit 2
fi
VERSION="$1"
BUILD="$2"
shift 2
RELEASE_URL=""
DOWNLOAD_URL=""
NOTES_URL=""
while (($#)); do
    case "$1" in
        --release-url) RELEASE_URL="${2:?missing URL}"; shift 2 ;;
        --download-url) DOWNLOAD_URL="${2:?missing URL}"; shift 2 ;;
        --notes-url) NOTES_URL="${2:?missing URL}"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
if [[ -n "$RELEASE_URL" ]]; then
    [[ -n "$DOWNLOAD_URL" ]] || DOWNLOAD_URL="$RELEASE_URL"
    [[ -n "$NOTES_URL" ]] || NOTES_URL="$RELEASE_URL"
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version must use MAJOR.MINOR.PATCH: $VERSION" >&2
    exit 2
fi
if [[ ! "$BUILD" =~ ^[1-9][0-9]*$ ]]; then
    echo "Build must be a positive integer: $BUILD" >&2
    exit 2
fi

/usr/bin/plutil -replace CFBundleShortVersionString -string "$VERSION" "$INFO_PLIST"
/usr/bin/plutil -replace CFBundleVersion -string "$BUILD" "$INFO_PLIST"
cat > "$VERSION_FILE" <<EOF_VERSION
# Single source for the app marketing version and monotonically increasing build.
FLOW_QUOTA_VERSION=$VERSION
FLOW_QUOTA_BUILD=$BUILD
EOF_VERSION

VERSION="$VERSION" BUILD="$BUILD" RELEASE_URL="$RELEASE_URL" \
DOWNLOAD_URL="$DOWNLOAD_URL" NOTES_URL="$NOTES_URL" MANIFEST="$MANIFEST" \
/usr/bin/python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["MANIFEST"])
with path.open(encoding="utf-8") as handle:
    manifest = json.load(handle)
manifest["version"] = os.environ["VERSION"]
manifest["build"] = int(os.environ["BUILD"])
for key, env_name in (("releaseNotesURL", "NOTES_URL"),
                      ("downloadURL", "DOWNLOAD_URL")):
    value = os.environ[env_name]
    if value:
        manifest[key] = value
with path.open("w", encoding="utf-8") as handle:
    json.dump(manifest, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY

echo "Version set to $VERSION (build $BUILD)"
