#!/bin/bash
# Reproducible safe tests, including CLT installations whose SwiftPM omits TestingMacros.
set -euo pipefail
cd "$(dirname "$0")/.."
MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --locked --release --lib --manifest-path rust/Cargo.toml
cargo test --locked --manifest-path rust/Cargo.toml
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
FLAGS=(--cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security")
SWIFTC="$(xcrun --find swiftc)"
TESTING_PLUGIN="$(dirname "$(dirname "$SWIFTC")")/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$TESTING_PLUGIN" ]]; then
    FLAGS+=(-Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN")
fi
swift test "${FLAGS[@]}" "$@"

/usr/bin/python3 -B -m unittest discover -s Tests/UninstallTests -p "test_*.py"
