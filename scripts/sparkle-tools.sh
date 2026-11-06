#!/bin/bash
# Fetch the matching official tools, verify the published archive digest, then
# check that the existing Keychain signing identity matches the committed key.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/.artifacts/sparkle-tools"
ARCHIVE="$TOOLS/Sparkle.tar.xz"
DIGEST="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
mkdir -p "$TOOLS"
if [[ ! -f "$ARCHIVE" ]]; then
    curl --fail --location --connect-timeout 15 --max-time 120 --retry 2 \
        -H 'Accept: application/octet-stream' \
        https://api.github.com/repos/sparkle-project/Sparkle/releases/assets/673946481 \
        -o "$ARCHIVE.partial"
    mv "$ARCHIVE.partial" "$ARCHIVE"
fi
[[ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" == "$DIGEST" ]] || {
    echo "Sparkle tools checksum mismatch; remove the cached archive and retry." >&2; exit 1;
}
# Extract only the tools; they stay outside the release asset directory.
tar -xf "$ARCHIVE" -C "$TOOLS" bin
if [[ "${1:-}" == --init-key ]]; then
    "$TOOLS/bin/generate_keys" --account local.flowquota.app >&2
fi
PUBLIC_KEY="$("$TOOLS/bin/generate_keys" --account local.flowquota.app -p)"
EXPECTED="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ROOT/macos/Configuration/Info.plist")"
[[ "$PUBLIC_KEY" == "$EXPECTED" ]] || {
    echo "Missing/mismatched Sparkle key. Import the original key into this Mac's Keychain; do not rotate the app public key." >&2; exit 1;
}
printf '%s\n' "$TOOLS/bin/sign_update"
