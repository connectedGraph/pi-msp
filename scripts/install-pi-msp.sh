#!/usr/bin/env bash
# install-pi-msp.sh — install the pi-msp standalone binary (MSP-sandboxed pi)
# to a user-level location and expose it on PATH.
#
# The delivery is self-contained: the bun-compiled `pi-msp` executable plus the
# in-process MSP kernel (`libMSPKernel.so`) and the bundled CPython runtime
# (`python/`) all live in packages/coding-agent/dist after a binary build. This
# script copies those three artifacts to a stable install dir and symlinks
# `pi-msp` onto the user PATH.
#
# Usage:
#   bash scripts/install-pi-msp.sh                  # install from local dist to ~/.pi-msp
#   bash scripts/install-pi-msp.sh --prefix ~/opt   # custom install root
#   bash scripts/install-pi-msp.sh --from <dir>     # custom source dir (must contain pi-msp + .so + python/)
#
# Env:
#   PREFIX (default ~/.pi-msp)   install root; binary goes to $PREFIX/bin/pi-msp
#   BIN_DIR (default ~/.local/bin) where the pi-msp symlink is placed
set -euo pipefail

# ---- resolve repo root (this script lives in scripts/) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- defaults ----
PREFIX="${PREFIX:-$HOME/.pi-msp}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
SOURCE_DIR="$REPO_ROOT/packages/coding-agent/dist"

# ---- arg parsing (keep it minimal) ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --bin-dir) BIN_DIR="$2"; shift 2 ;;
    --from) SOURCE_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ---- required artifacts ----
for artifact in pi-msp libMSPKernel.so; do
  if [[ ! -f "$SOURCE_DIR/$artifact" ]]; then
    echo "error: $SOURCE_DIR/$artifact not found." >&2
    echo "Build it first: cd $REPO_ROOT && bash packages/msp-kernel/build.sh && npm --prefix packages/coding-agent run build:binary" >&2
    exit 1
  fi
done
if [[ ! -d "$SOURCE_DIR/python" ]]; then
  echo "error: $SOURCE_DIR/python not found. Bundle it first:" >&2
  echo "  bash $REPO_ROOT/packages/msp-kernel/bundle-python.sh $SOURCE_DIR" >&2
  exit 1
fi

# ---- install ----
echo "==> installing pi-msp from $SOURCE_DIR"
mkdir -p "$PREFIX/bin"
cp -f "$SOURCE_DIR/pi-msp" "$PREFIX/bin/pi-msp"
cp -f "$SOURCE_DIR/libMSPKernel.so" "$PREFIX/bin/libMSPKernel.so"
# python/ bundle must sit next to the binary (msp-runtime resolves <exe>/python)
rm -rf "$PREFIX/bin/python"
cp -r "$SOURCE_DIR/python" "$PREFIX/bin/python"
chmod +x "$PREFIX/bin/pi-msp"

echo "==> linking $PREFIX/bin/pi-msp -> $BIN_DIR/pi-msp"
mkdir -p "$BIN_DIR"
ln -sf "$PREFIX/bin/pi-msp" "$BIN_DIR/pi-msp"

echo ""
echo "pi-msp installed at $PREFIX"
echo "  binary:  $PREFIX/bin/pi-msp"
echo "  kernel:  $PREFIX/bin/libMSPKernel.so"
echo "  python:  $PREFIX/bin/python"
echo ""
echo "symlink:  $BIN_DIR/pi-msp -> $PREFIX/bin/pi-msp"
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo ""
  echo "Add to your PATH (e.g. in ~/.bashrc):"
  echo "  export PATH=\"$BIN_DIR:\$PATH\""
fi
echo ""
echo "Verify: $BIN_DIR/pi-msp --version"
