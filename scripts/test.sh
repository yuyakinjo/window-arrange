#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
SWIFT_FLAGS=(--cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security")
if [[ "${WINDOW_ARRANGE_NESTED_SANDBOX:-0}" == 1 ]]; then
  SWIFT_FLAGS+=(--disable-sandbox)
fi
SWIFT_COMPILER="$(xcrun --find swiftc)"
MACRO_LIBRARY="${SWIFT_COMPILER:h:h}/lib/swift/host/plugins/testing/libTestingMacros.dylib"
# Some Command Line Tools releases omit the automatic Testing macro search path.
if [[ -f "$MACRO_LIBRARY" ]]; then
  SWIFT_FLAGS+=(-Xswiftc -load-plugin-library -Xswiftc "$MACRO_LIBRARY")
fi
swift test --disable-xctest "${SWIFT_FLAGS[@]}"
