#!/bin/sh
# build/wren.app を組み立てる。zig build → swift build → バンドルに詰める。
# CONFIG=release で最適化ビルド（既定は debug）。
set -eu
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-debug}"
case "$CONFIG" in
  debug) ZIG_OPT=Debug ;;
  release) ZIG_OPT=ReleaseFast ;;
  *) echo "CONFIG は debug か release: $CONFIG" >&2; exit 1 ;;
esac

zig build -Doptimize="$ZIG_OPT"
swift build -c "$CONFIG" --arch arm64
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

APP=build/wren.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/wren" "$APP/Contents/MacOS/wren"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "$APP"
