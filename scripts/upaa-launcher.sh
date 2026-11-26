#!/bin/sh
# upaa コマンド。.app の Contents/Resources/bin/upaa に入り、インストーラが PATH の通った場所からリンクする。
#   upaa            アプリを開く
#   upaa update     最新のリリースを入れ直す
#   upaa <引数...>  アプリの実行ファイルに引数を渡す（--version など）
set -eu

SELF="$(realpath "$0")"
APP="${SELF%/Contents/Resources/bin/upaa}"

case "${1:-}" in
  "")
    exec open "$APP"
    ;;
  update)
    curl -fsSL --proto '=https' https://raw.githubusercontent.com/Matuyuhi/upaa/main/install.sh | sh
    ;;
  *)
    exec "$APP/Contents/MacOS/upaa" "$@"
    ;;
esac
