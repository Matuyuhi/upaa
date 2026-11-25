#!/bin/sh
# 手元と CI で同じテストを流す。
#   1. Zig のテスト
#   2. アプリのビルドとリンクの確認
#   3. 画面の書き出しを基準の画像（tests/snapshots/）と比べる
#   4. 速さが下限・上限を外れていないか
# UPDATE_SNAPSHOTS=1 を付けると、基準の画像を今の描画で置き換える。
set -eu
cd "$(dirname "$0")/.."

zig build test --summary all

CONFIG=release sh scripts/build-app.sh
BIN=build/uparupa.app/Contents/MacOS/uparupa
"$BIN" --check

mkdir -p build/snapshots tests/snapshots
for vt in tests/fixtures/*.vt; do
  name="$(basename "$vt" .vt)"
  "$BIN" --snapshot "build/snapshots/$name.png" --command "cat '$PWD/$vt'"
  if [ "${UPDATE_SNAPSHOTS:-0}" = 1 ]; then
    cp "build/snapshots/$name.png" "tests/snapshots/$name.png"
    echo "基準を更新: tests/snapshots/$name.png"
  else
    printf '%s: ' "$name"
    "$BIN" --compare-png "tests/snapshots/$name.png" "build/snapshots/$name.png"
  fi
done

# 共有の CI では速さがぶれるので、桁が違うほど遅くなったときだけ失敗させる。
if [ ! -f build/bench.txt ]; then
  base64 -i /dev/urandom -b 100 | head -c 20000000 > build/bench.txt
fi
"$BIN" --bench-headless "$PWD/build/bench.txt" --max-frame-ms 5 --min-mb-per-s 10

echo "すべて通った"
