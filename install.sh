#!/bin/sh
# uparupa を入れる（入れ直す）。
#   curl -fsSL https://raw.githubusercontent.com/Matuyuhi/uparupa/main/install.sh | sh
#
# やること:
#   1. GitHub の Releases から uparupa-macos-arm64.zip と SHA256SUMS を取得する
#   2. SHA-256 が一致したときだけ展開する
#   3. ~/Applications/uparupa.app に置き、~/.local/bin/uparupa から呼べるようにする
# 管理者権限は使わない。
#
# 環境変数:
#   UPARUPA_VERSION        入れるバージョン（v0.1.0 の形）。省略すると最新
#   UPARUPA_APP_DIR        .app を置く場所（既定 ~/Applications）
#   UPARUPA_BIN_DIR        コマンドを置く場所（既定 ~/.local/bin）
#   UPARUPA_DOWNLOAD_BASE  取得元（既定は GitHub の Releases。手元での確認用）
set -eu

REPO=Matuyuhi/uparupa
ZIP=uparupa-macos-arm64.zip
APP_DIR="${UPARUPA_APP_DIR:-$HOME/Applications}"
BIN_DIR="${UPARUPA_BIN_DIR:-$HOME/.local/bin}"

fail() {
  echo "uparupa: $1" >&2
  exit 1
}

[ "$(uname -s)" = Darwin ] || fail "macOS 専用です"
[ "$(uname -m)" = arm64 ] || fail "Apple Silicon（arm64）専用です"
major="$(sw_vers -productVersion | cut -d . -f 1)"
[ "$major" -ge 13 ] || fail "macOS 13 以上が必要です（今は $(sw_vers -productVersion)）"

if [ -n "${UPARUPA_DOWNLOAD_BASE:-}" ]; then
  base="$UPARUPA_DOWNLOAD_BASE"
elif [ -n "${UPARUPA_VERSION:-}" ]; then
  base="https://github.com/$REPO/releases/download/$UPARUPA_VERSION"
else
  base="https://github.com/$REPO/releases/latest/download"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/uparupa.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

echo "取得: $base/$ZIP"
curl -fsSL --proto '=https,file' -o "$tmp/$ZIP" "$base/$ZIP" || fail "ダウンロードに失敗しました"
curl -fsSL --proto '=https,file' -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" || fail "SHA256SUMS のダウンロードに失敗しました"

expected="$(awk -v f="$ZIP" '{ n = $2; sub(/^\*/, "", n); if (n == f) print $1 }' "$tmp/SHA256SUMS")"
actual="$(shasum -a 256 "$tmp/$ZIP" | cut -d ' ' -f 1)"
[ -n "$expected" ] && [ "$expected" = "$actual" ] || fail "SHA-256 が一致しません: expected=${expected} actual=${actual}"

ditto -x -k "$tmp/$ZIP" "$tmp/unpacked"
[ -x "$tmp/unpacked/uparupa.app/Contents/MacOS/uparupa" ] || fail "zip の中身が想定と違います"
version="$("$tmp/unpacked/uparupa.app/Contents/MacOS/uparupa" --version)"

mkdir -p "$APP_DIR" "$BIN_DIR"
rm -rf "$APP_DIR/uparupa.app"
mv "$tmp/unpacked/uparupa.app" "$APP_DIR/uparupa.app"
ln -sf "$APP_DIR/uparupa.app/Contents/Resources/bin/uparupa" "$BIN_DIR/uparupa"

echo "uparupa $version を入れました: $APP_DIR/uparupa.app"
case ":$PATH:" in
  *":$BIN_DIR:"*) echo "起動: uparupa" ;;
  *) echo "起動: $BIN_DIR/uparupa（$BIN_DIR を PATH に入れると uparupa だけで起動できます）" ;;
esac
