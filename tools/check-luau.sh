#!/usr/bin/env bash
# Syntax-check the Roblox scripts with the REAL Luau compiler.
#
# `luac -p` is not a substitute. Lua 5.4 accepts `goto` and `::labels::`;
# Luau has neither, so a script that passed `luac5.4 -p` still failed to
# compile in Roblox, loadstring() returned nil, and the loader died with
# "attempt to call a nil value". This uses Luau itself, so it cannot lie.
set -euo pipefail
cd "$(dirname "$0")/.."

CACHE="${LUAU_DIR:-${TMPDIR:-/tmp}/luau-bin}"
BIN="$CACHE/luau-compile"

if [ ! -x "$BIN" ]; then
  echo "downloading luau..."
  mkdir -p "$CACHE"
  case "$(uname -s)" in
    Darwin) ASSET=luau-macos.zip ;;
    *)      ASSET=luau-ubuntu.zip ;;
  esac
  URL="https://github.com/luau-lang/luau/releases/latest/download/$ASSET"
  curl -fsSL "$URL" -o "$CACHE/luau.zip"
  unzip -oq "$CACHE/luau.zip" -d "$CACHE"
  chmod +x "$CACHE"/luau*
fi

fail=0
for f in scripts/*.lua; do
  if "$BIN" --null "$f" >/dev/null 2>"$CACHE/err"; then
    echo "ok    $f"
  else
    echo "FAIL  $f"
    sed 's/^/      /' "$CACHE/err"
    fail=1
  fi
done
exit $fail
