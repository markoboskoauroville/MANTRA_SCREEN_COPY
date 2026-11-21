#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TARGET="$HOME/.local/bin/screencopy"

mkdir -p "$(dirname "$TARGET")"
chmod +x "$SCRIPT_DIR/screencopy.py"
ln -sfn "$SCRIPT_DIR/screencopy.py" "$TARGET"
echo "installed $TARGET -> $SCRIPT_DIR/screencopy.py"
