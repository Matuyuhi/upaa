#!/bin/sh
# build/upaa.app を組み立てる。zig build → swift build → バンドルに詰める。
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
# SwiftPM のリンクは SDK のバージョンを最低 OS と同じ 13.0 と記録してしまう。
# AppKit はこの値で振る舞いを切り替えるので、実際の SDK のバージョンを渡す。
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
set -- -c "$CONFIG" --arch arm64 \
  -Xlinker -platform_version -Xlinker macos -Xlinker 13.0 -Xlinker "$SDK_VERSION"
swift build "$@"
BIN_DIR="$(swift build "$@" --show-bin-path)"

APP=build/upaa.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/upaa" "$APP/Contents/MacOS/upaa"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# バージョンは build.zig.zon だけに書いてある。ビルドした実行ファイルに聞いて Info.plist に入れる。
VERSION="$("$APP/Contents/MacOS/upaa" --version)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

mkdir -p "$APP/Contents/Resources/bin"
cp LICENSE THIRD_PARTY_LICENSES.md "$APP/Contents/Resources/"
cp scripts/upaa-launcher.sh "$APP/Contents/Resources/bin/upaa"
chmod +x "$APP/Contents/Resources/bin/upaa"

# シェーダは default.metallib にして Resources に置く（Swift 側は makeDefaultLibrary で読む）。
mkdir -p "$APP/Contents/Resources" build/shaders
xcrun -sdk macosx metal -c Shaders/terminal.metal -mmacosx-version-min=13.0 -o build/shaders/terminal.air
xcrun -sdk macosx metallib build/shaders/terminal.air -o "$APP/Contents/Resources/default.metallib"
codesign --force --sign - "$APP"

echo "$APP"
