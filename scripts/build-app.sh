#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
CONFIGURATION="${1:-release}"
if [[ "$CONFIGURATION" != release && "$CONFIGURATION" != debug ]]; then
  print -u2 'Usage: ./scripts/build-app.sh [release|debug]'
  exit 1
fi
SWIFT_FLAGS=(--cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security")
if [[ "$CONFIGURATION" == release ]]; then
  SWIFT_FLAGS+=(-debug-info-format none)
fi
# Needed only inside environments which already sandbox the build process.
if [[ "${WINDOW_ARRANGE_NESTED_SANDBOX:-0}" == 1 ]]; then
  SWIFT_FLAGS+=(--disable-sandbox)
fi
swift build -c "$CONFIGURATION" "${SWIFT_FLAGS[@]}"
BIN_DIR="$(swift build -c "$CONFIGURATION" "${SWIFT_FLAGS[@]}" --show-bin-path)"
APP_DIR="$PWD/dist/Window Arrange.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/WindowArrange" "$APP_DIR/Contents/MacOS/WindowArrange"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
codesign --force --sign - --identifier local.windowarrange.app "$APP_DIR"
print "Built: $APP_DIR"
