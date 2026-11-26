#!/bin/sh
# Assemble build/upaa.app: zig build → swift build → pack into the bundle.
# CONFIG=release for an optimized build (default is debug).
set -eu
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-debug}"
case "$CONFIG" in
  debug) ZIG_OPT=Debug ;;
  release) ZIG_OPT=ReleaseFast ;;
  *) echo "CONFIG must be debug or release: $CONFIG" >&2; exit 1 ;;
esac

zig build -Doptimize="$ZIG_OPT"
# The Swift driver gives clang the SDK as --sysroot, but clang reads the SDK version only from -isysroot or
# SDKROOT. xcrun sets SDKROOT; SwiftPM runs the toolchain directly without it, so the executable would record
# the SDK version as the minimum OS (13.0). AppKit changes behavior based on that value, so pass -isysroot.
SDK="$(xcrun --sdk macosx --show-sdk-path)"
set -- -c "$CONFIG" --arch arm64 \
  -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$SDK"
swift build "$@"
BIN_DIR="$(swift build "$@" --show-bin-path)"

APP=build/upaa.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/upaa" "$APP/Contents/MacOS/upaa"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The version is written only in build.zig.zon. Ask the built executable and put it into Info.plist.
VERSION="$("$APP/Contents/MacOS/upaa" --version)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

mkdir -p "$APP/Contents/Resources/bin"
cp LICENSE THIRD_PARTY_LICENSES.md "$APP/Contents/Resources/"
cp scripts/upaa-launcher.sh "$APP/Contents/Resources/bin/upaa"
chmod +x "$APP/Contents/Resources/bin/upaa"

# Shaders go into default.metallib in Resources (the Swift side reads it with makeDefaultLibrary).
mkdir -p "$APP/Contents/Resources" build/shaders
xcrun -sdk macosx metal -c Shaders/terminal.metal -mmacosx-version-min=13.0 -o build/shaders/terminal.air
xcrun -sdk macosx metallib build/shaders/terminal.air -o "$APP/Contents/Resources/default.metallib"
codesign --force --sign - "$APP"

echo "$APP"
