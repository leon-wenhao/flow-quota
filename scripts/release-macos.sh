#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT/macos/Configuration/version.env"
REPO="leon-wenhao/flow-quota-releases"
OUTPUT_DIR=""
PUBLISH=false
ACTIVATE=false
VERSION="$(awk -F= '$1 == "FLOW_QUOTA_VERSION" { print $2 }' "$VERSION_FILE")"
BUILD="$(awk -F= '$1 == "FLOW_QUOTA_BUILD" { print $2 }' "$VERSION_FILE")"

usage() {
    cat <<'USAGE'
Usage: scripts/release-macos.sh [options]

Build two macOS DMGs and an audited release bundle. Source remains private.
  --output-dir PATH        New local output directory
  --publish                Publish to the independent public repository through GitHub REST API
  --activate-manifest      Activate public main manifest after release verification
  --repo OWNER/REPO        Must be leon-wenhao/flow-quota-releases

Set versions with scripts/set-version.sh before building.
Resume publication without rebuilding:
  python3 scripts/publish_macos.py --bundle PATH --activate-manifest
USAGE
}
while (($#)); do
    case "$1" in
        --output-dir) OUTPUT_DIR="${2:?missing PATH}"; shift 2 ;;
        --publish) PUBLISH=true; shift ;;
        --activate-manifest) ACTIVATE=true; shift ;;
        --repo) REPO="${2:?missing OWNER/REPO}"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ "$REPO" == "leon-wenhao/flow-quota-releases" ]] || {
    echo "Only the independent public distribution repository is permitted." >&2; exit 2;
}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[1-9][0-9]*$ ]] || {
    echo "Invalid canonical version/build." >&2; exit 2;
}
if $ACTIVATE && ! $PUBLISH; then
    echo "--activate-manifest requires --publish." >&2; exit 2
fi
if $PUBLISH; then
    [[ -z "$(git -C "$ROOT" status --porcelain)" ]] || {
        echo "Commit reviewed source changes before publishing." >&2; exit 1;
    }
    command -v gh >/dev/null || { echo "Install gh and authenticate first." >&2; exit 1; }
    gh auth status --hostname github.com >/dev/null
    /usr/bin/python3 "$ROOT/scripts/public_repository.py" --repo "$REPO"
fi
INFO="$ROOT/macos/Configuration/Info.plist"
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$INFO")" == "$VERSION" &&
   "$(/usr/bin/plutil -extract CFBundleVersion raw "$INFO")" == "$BUILD" ]] || {
    echo "Info.plist mismatch; run scripts/set-version.sh first." >&2; exit 1;
}
/usr/bin/python3 - "$ROOT/update-manifest.json" "$VERSION" "$BUILD" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    manifest = json.load(source)
if (manifest['version'], manifest['build']) != (sys.argv[2], int(sys.argv[3])):
    raise SystemExit('Source manifest mismatch; run scripts/set-version.sh first.')
PY
[[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="$ROOT/.artifacts/releases/FlowQuota-$VERSION-build-$BUILD"
[[ "$OUTPUT_DIR" = /* ]] || OUTPUT_DIR="$ROOT/$OUTPUT_DIR"
[[ ! -e "$OUTPUT_DIR" ]] || { echo "Output already exists; choose a new directory." >&2; exit 1; }
mkdir -p "$OUTPUT_DIR"
"$ROOT/scripts/build-macos.sh" --release --arm64 --dmg-output "$OUTPUT_DIR/FlowQuota-$VERSION-arm64.dmg"
"$ROOT/scripts/build-macos.sh" --release --x64 --dmg-output "$OUTPUT_DIR/FlowQuota-$VERSION-x86_64.dmg"
/usr/bin/python3 "$ROOT/scripts/release_bundle.py" prepare --output "$OUTPUT_DIR" \
    --source-manifest "$ROOT/update-manifest.json" --repo "$REPO" --version "$VERSION" --build "$BUILD"
if $PUBLISH; then
    ARGS=(--bundle "$OUTPUT_DIR" --repo "$REPO")
    if $ACTIVATE; then ARGS+=(--activate-manifest); fi
    /usr/bin/python3 "$ROOT/scripts/publish_macos.py" "${ARGS[@]}"
fi
printf 'Release bundle prepared: %s\n' "$OUTPUT_DIR"
