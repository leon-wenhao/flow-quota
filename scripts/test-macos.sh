#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$ROOT/.artifacts/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.artifacts/cache/swift"
/usr/bin/python3 "$ROOT/shared/test-vectors/sync-fixtures.py" --check
xcrun swift test --package-path "$ROOT/macos" --scratch-path "$ROOT/.artifacts/tests" \
    --cache-path "$ROOT/.artifacts/swiftpm/cache" \
    --config-path "$ROOT/.artifacts/swiftpm/config" \
    --security-path "$ROOT/.artifacts/swiftpm/security" \
    --disable-sandbox "$@"
