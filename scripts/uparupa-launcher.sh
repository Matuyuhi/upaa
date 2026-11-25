#!/bin/sh
# uparupa コマンド。.app の Contents/Resources/bin/uparupa に入り、インストーラが PATH の通った場所からリンクする。
#   uparupa            アプリを開く
#   uparupa update     最新のリリースを入れ直す
#   uparupa <引数...>  アプリの実行ファイルに引数を渡す（--version など）
set -eu

SELF="$(realpath "$0")"
APP="${SELF%/Contents/Resources/bin/uparupa}"

case "${1:-}" in
  "")
    exec open "$APP"
    ;;
  update)
    curl -fsSL --proto '=https' https://raw.githubusercontent.com/Matuyuhi/uparupa/main/install.sh | sh
    ;;
  *)
    exec "$APP/Contents/MacOS/uparupa" "$@"
    ;;
esac
