#!/usr/bin/env bash
#
# Bundle a self-contained CPython runtime (libpython + stdlib) next to the
# pi-shell executable, so python3 works without depending on the host's
# /usr/lib python installation.
#
# The MSPKernelShim resolves libpython / PYTHONHOME in this order:
#   1. $MSP_PYTHON_LIB           explicit libpython path
#   2. <exe>/python/lib/libpython3.x.so      this bundle
#   3. system libpython
#   pythonHome: $MSP_PYTHON_HOME, else <exe>/python  (this bundle)
#
# Bundle layout (rooted-install shape — CPython's getpath requires the stdlib
# under <home>/lib/pythonX.Y; a bare <home>/pythonX.Y fails to import encodings):
#   <dest>/python/lib/libpython3.x.so.1.0   (real file, copied from host)
#   <dest>/python/lib/libpython3.x.so       (symlink -> the real file)
#   <dest>/python/lib/python3.x/            (copy of the host stdlib, incl. lib-dynload)
#
# Usage:
#   bash bundle-python.sh <dest-dir>         # dest-dir holds the pi-shell binary
#   bash bundle-python.sh <dest-dir> <ver>   # e.g. 3.14 (default: current python3)
set -euo pipefail

DEST="${1:?usage: bash bundle-python.sh <dest-dir> [python-version]}"
VER="${2:-}"

PY="$(command -v python3)"
if [[ -z "$VER" ]]; then
    VER="$("$PY" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
fi
LIBDIR="$("$PY" -c 'import sysconfig; print(sysconfig.get_config_var("LIBDIR"))')"          # e.g. /usr/lib/x86_64-linux-gnu
STDLIB="$("$PY" -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')"                # e.g. /usr/lib/python3.14

OUT="$DEST/python"
mkdir -p "$OUT/lib"

# Resolve the real shared object (follow any versioned symlink chain), then lay
# down a REAL file plus the versioned symlink the stdlib .so extensions need.
REAL=""
for f in "$LIBDIR"/libpython"$VER".so*; do
    [[ -e "$f" ]] || continue
    REAL="$(readlink -f "$f")"
    break
done
if [[ -z "$REAL" ]]; then
    echo "error: no libpython$VER.so* found in $LIBDIR" >&2
    exit 1
fi
echo "==> copying libpython: $REAL"
cp "$REAL" "$OUT/lib/$(basename "$REAL")"
ln -sfn "$(basename "$REAL")" "$OUT/lib/libpython$VER.so"

# stdlib (dereference so a symlinked stdlib dir becomes a real copy) -> <home>/lib/pythonX.Y
echo "==> copying stdlib: $STDLIB -> $OUT/lib/"
cp -rL "$STDLIB" "$OUT/lib/"

echo "==> bundle created: $OUT"
ls -la "$OUT" "$OUT/lib" | head -12
echo "    size: $(du -sh "$OUT" | cut -f1)"