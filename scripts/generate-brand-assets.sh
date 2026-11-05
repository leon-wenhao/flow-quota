#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$ROOT/.artifacts/cache/clang"
TOOLS="$ROOT/.artifacts/brand-tools"
ICONSET="$TOOLS/FlowQuota.iconset"
mkdir -p "$TOOLS"
xcrun swiftc -parse-as-library -swift-version 6 \
    "$ROOT/macos/Sources/FlowQuotaApp/BrandIdentity.swift" \
    "$ROOT/scripts/GenerateBrandAssets.swift" -o "$TOOLS/generate-brand-assets"
"$TOOLS/generate-brand-assets" "$ROOT/assets/brand" "$ICONSET"
/usr/bin/iconutil --convert icns --output "$ROOT/assets/brand/FlowQuota.icns" "$ICONSET"
