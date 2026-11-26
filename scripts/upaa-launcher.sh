#!/bin/sh
# upaa command. It lives at Contents/Resources/bin/upaa in the .app, and the installer links it from a location on PATH.
#   upaa            Open the app
#   upaa update     Reinstall the latest release
#   upaa <args...>  Pass arguments to the app executable (such as --version)
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
