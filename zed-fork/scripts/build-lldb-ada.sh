#!/usr/bin/env bash
# Build a liblldb carrying the Ada type-system patches in ../patches, so
# codelldb can be repackaged around it. See ../docs/lldb-ada-debugging.md.
#
# The patches are validated against the pinned LLVM commit below; CI (and your
# Mac) clone that exact commit, apply the patches, and build. The checkout is a
# throwaway under $WORK and is never committed back into this repo.
set -euo pipefail

# release/19.x pin the patches were developed and compile-checked against.
LLVM_REF="${LLVM_REF:-cd708029e0b2869e80abe31ddb175f7c35361f90}"
LLVM_REPO="${LLVM_REPO:-https://github.com/llvm/llvm-project.git}"
WORK="${WORK:-$PWD/.lldb-ada-build}"
SRC="$WORK/llvm-project"
BUILD="$WORK/build"
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
PATCHES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../patches" && pwd)"

echo ">> LLVM $LLVM_REF -> $SRC (jobs=$JOBS)"

# 1. Fetch the exact pinned commit (shallow, ~2 GB working tree).
mkdir -p "$WORK"
if [ ! -e "$SRC/.git" ]; then
  git init -q "$SRC"
  git -C "$SRC" remote add origin "$LLVM_REPO" 2>/dev/null || true
  git -C "$SRC" fetch --depth 1 origin "$LLVM_REF"
  git -C "$SRC" checkout -q FETCH_HEAD
fi

# 2. Apply every patch in ../patches (idempotent: a clean reverse-check means
#    it is already applied, so skip it rather than fail on re-runs).
shopt -s nullglob
for p in "$PATCHES_DIR"/*.patch; do
  if git -C "$SRC" apply --reverse --check "$p" 2>/dev/null; then
    echo "   already applied: $(basename "$p")"
  else
    git -C "$SRC" apply "$p"
    echo "   applied: $(basename "$p")"
  fi
done
shopt -u nullglob

# 3. Configure + build liblldb. PYTHON defaults ON (needs swig) for a usable
#    codelldb; set LLDB_ENABLE_PYTHON=OFF for a quick compile-check.
# CMAKE_ARGS lets callers inject extra flags, e.g. a ccache launcher in CI:
#   CMAKE_ARGS="-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
cmake -S "$SRC/llvm" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE:-Release}" \
  -DLLVM_ENABLE_PROJECTS="clang;lldb" \
  -DLLVM_TARGETS_TO_BUILD="${TARGETS:-AArch64;X86}" \
  -DLLVM_ENABLE_ASSERTIONS="${ASSERTIONS:-OFF}" \
  -DLLDB_ENABLE_PYTHON="${LLDB_ENABLE_PYTHON:-ON}" \
  -DLLDB_ENABLE_LUA=OFF \
  ${CMAKE_ARGS:-}

ninja -C "$BUILD" -j"$JOBS" liblldb

echo ">> liblldb built: $BUILD/lib"
echo ">> repackage codelldb against it, then point provision-toolchain.sh at"
echo "   the result via \$CODELLDB_DIST."
