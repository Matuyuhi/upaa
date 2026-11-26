#!/bin/sh
# Install (or reinstall) upaa.
#   curl -fsSL https://raw.githubusercontent.com/Matuyuhi/upaa/main/install.sh | sh
#
# What it does:
#   1. Downloads upaa-macos-arm64.zip and SHA256SUMS from GitHub Releases
#   2. Unpacks the zip only if its SHA-256 matches
#   3. Puts the app in ~/Applications/upaa.app and links ~/.local/bin/upaa to it
# No administrator rights are used.
#
# Environment variables:
#   UPAA_VERSION        version to install, like v0.1.0 (default: latest)
#   UPAA_APP_DIR        where to put the app (default: ~/Applications)
#   UPAA_BIN_DIR        where to put the command (default: ~/.local/bin)
#   UPAA_DOWNLOAD_BASE  where to download from (default: GitHub Releases; for local testing)
set -eu

REPO=Matuyuhi/upaa
ZIP=upaa-macos-arm64.zip
APP_DIR="${UPAA_APP_DIR:-$HOME/Applications}"
BIN_DIR="${UPAA_BIN_DIR:-$HOME/.local/bin}"

fail() {
  echo "upaa: $1" >&2
  exit 1
}

[ "$(uname -s)" = Darwin ] || fail "upaa only runs on macOS"
[ "$(uname -m)" = arm64 ] || fail "upaa only runs on Apple Silicon (arm64)"
major="$(sw_vers -productVersion | cut -d . -f 1)"
[ "$major" -ge 13 ] || fail "macOS 13 or later is required (this is $(sw_vers -productVersion))"

if [ -n "${UPAA_DOWNLOAD_BASE:-}" ]; then
  base="$UPAA_DOWNLOAD_BASE"
elif [ -n "${UPAA_VERSION:-}" ]; then
  base="https://github.com/$REPO/releases/download/$UPAA_VERSION"
else
  base="https://github.com/$REPO/releases/latest/download"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/upaa.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading $base/$ZIP"
curl -fsSL --proto '=https,file' -o "$tmp/$ZIP" "$base/$ZIP" || fail "download failed"
curl -fsSL --proto '=https,file' -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" || fail "could not download SHA256SUMS"

expected="$(awk -v f="$ZIP" '{ n = $2; sub(/^\*/, "", n); if (n == f) print $1 }' "$tmp/SHA256SUMS")"
actual="$(shasum -a 256 "$tmp/$ZIP" | cut -d ' ' -f 1)"
[ -n "$expected" ] && [ "$expected" = "$actual" ] || fail "SHA-256 mismatch: expected=${expected} actual=${actual}"

ditto -x -k "$tmp/$ZIP" "$tmp/unpacked"
[ -x "$tmp/unpacked/upaa.app/Contents/MacOS/upaa" ] || fail "the zip does not contain upaa.app"
version="$("$tmp/unpacked/upaa.app/Contents/MacOS/upaa" --version)"

mkdir -p "$APP_DIR" "$BIN_DIR"
rm -rf "$APP_DIR/upaa.app"
mv "$tmp/unpacked/upaa.app" "$APP_DIR/upaa.app"
ln -sf "$APP_DIR/upaa.app/Contents/Resources/bin/upaa" "$BIN_DIR/upaa"

echo "Installed upaa $version at $APP_DIR/upaa.app"
case ":$PATH:" in
  *":$BIN_DIR:"*) echo "Run: upaa" ;;
  *) echo "Run: $BIN_DIR/upaa (add $BIN_DIR to your PATH to run it as just upaa)" ;;
esac
