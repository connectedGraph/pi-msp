#!/usr/bin/env bash
# Build libMSPKernel.so — the MSP sandbox kernel shared library for pi-shell.
#
# The kernel is the vendored ModelShellProxy (MSP) shell runtime compiled to a
# C ABI shared library. pi-shell loads it in-process via Bun FFI, so commands
# execute inside the MSP sandbox without spawning any external process.
#
# Prerequisites (WSL Ubuntu / Debian): Swift toolchain 5.9+.
#
# Usage:
#   bash build.sh                 # release build
#   bash build.sh -c debug        # debug build (faster iteration)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/swift"

swift build "$@"

LIB="$(ls .build/*/libMSPKernel.so 2>/dev/null | head -1)"
if [ -z "$LIB" ]; then
  echo "error: libMSPKernel.so not produced" >&2
  exit 1
fi
echo "==> built: $SCRIPT_DIR/swift/$LIB"
echo "    (pi-shell should load this .so; set LD_LIBRARY_PATH to the Swift toolchain lib dir if dlopen fails)"
