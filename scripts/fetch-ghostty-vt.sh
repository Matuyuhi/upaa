#!/bin/sh
# libghostty-vt の XCFramework を取得し、署名と SHA-256 を確かめてから vendor/ghostty-vt に展開する。
set -eu
cd "$(dirname "$0")/.."

VERSION=1.0.2
BASE="https://release.files.ghostty.org/libghostty-vt/$VERSION"
ZIP="ghostty-vt-$VERSION.xcframework.zip"
# タグ vt-$VERSION の PACKAGING-LIBGHOSTTY.md に載っている公開鍵
PUBKEY=RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV
DEST=vendor/ghostty-vt
# 初回の取得で署名と SHA256SUMS を確かめたときの値。配布物が差し替えられていたら止まる。
ZIP_SHA256=15477209ce86ad1c944f217e925c84acf796ecc51aba7a935aaa1a7769890bd6

command -v minisign >/dev/null || { echo "minisign が必要（brew install minisign）" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ghostty-vt.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

for f in "$ZIP" "$ZIP.minisig" SHA256SUMS SHA256SUMS.minisig; do
  curl -fsSL --proto =https -o "$TMP/$f" "$BASE/$f"
done

minisign -V -q -P "$PUBKEY" -m "$TMP/SHA256SUMS"
minisign -V -q -P "$PUBKEY" -m "$TMP/$ZIP"

expected="$(awk -v f="$ZIP" '{ n = $2; sub(/^\*/, "", n); sub(/^\.\//, "", n); if (n == f) print $1 }' "$TMP/SHA256SUMS")"
actual="$(shasum -a 256 "$TMP/$ZIP" | cut -d ' ' -f 1)"
if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
  echo "SHA-256 が SHA256SUMS と一致しない: expected=$expected actual=$actual" >&2
  exit 1
fi
if [ "$actual" != "$ZIP_SHA256" ]; then
  echo "SHA-256 がスクリプトに固定した値と一致しない: pinned=$ZIP_SHA256 actual=$actual" >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST"
unzip -q "$TMP/$ZIP" -d "$DEST"
echo "$VERSION" > "$DEST/VERSION"
echo "sha256 $actual"
echo "$DEST"
