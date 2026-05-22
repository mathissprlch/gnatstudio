#!/usr/bin/env bash
# Repackage codelldb so its bundled liblldb is our Ada-patched build.
#
# codelldb's adapter loads liblldb via the stable LLDB SB API; v1.11.5 bundles
# LLDB 19.1.0, and our patch builds 19.1.x, so swapping the dylib is ABI-safe.
# Produces a directory tree (containing extension/) suitable for
# provision-toolchain.sh's $CODELLDB_DIST; the workflow also zips it to a .vsix.
#
# Usage:
#   LIBLLDB=/path/to/liblldb.dylib-or-dir OUTDIR=/path/to/out \
#     [CODELLDB_VERSION=v1.11.5] [CODELLDB_VSIX=/local/codelldb.vsix] \
#     bash repackage-codelldb.sh
set -euo pipefail

CODELLDB_VERSION="${CODELLDB_VERSION:-v1.11.5}"   # bundles LLDB 19.1.0
LIBLLDB="${LIBLLDB:?set LIBLLDB to the patched liblldb dylib (or its directory)}"
OUTDIR="${OUTDIR:-$PWD/codelldb-ada}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "repackage-codelldb.sh must run on macOS (needs otool/install_name_tool/codesign)" >&2
  exit 1
fi

# Resolve LIBLLDB to a real (non-symlink) dylib file.
if [[ -d "$LIBLLDB" ]]; then
  LIBLLDB="$(/usr/bin/find "$LIBLLDB" -maxdepth 1 -name 'liblldb*.dylib' -type f | head -1)"
fi
[[ -f "$LIBLLDB" ]] || { echo "no liblldb dylib found at LIBLLDB" >&2; exit 1; }
echo ">> patched liblldb: $LIBLLDB ($(du -h "$LIBLLDB" | cut -f1))"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 1. Obtain the codelldb vsix (local override or download).
vsix="${CODELLDB_VSIX:-}"
if [[ -z "$vsix" ]]; then
  vsix="$work/codelldb.vsix"
  base="https://github.com/vadimcn/codelldb/releases/download/${CODELLDB_VERSION}"
  ok=""
  for n in codelldb-aarch64-darwin.vsix codelldb-darwin-arm64.vsix; do
    echo ">> downloading $base/$n"
    if curl -fSL --output "$vsix" "$base/$n"; then ok=1; break; fi
  done
  [[ -n "$ok" ]] || { echo "could not download codelldb $CODELLDB_VERSION" >&2; exit 1; }
fi

# 2. Extract.
rm -rf "$OUTDIR"; mkdir -p "$OUTDIR"
( cd "$OUTDIR" && unzip -q "$vsix" )

adapter="$OUTDIR/extension/adapter/codelldb"
libdir="$OUTDIR/extension/lldb/lib"
[[ -x "$adapter" ]] || { echo "adapter missing in vsix ($adapter)" >&2; exit 1; }
[[ -d "$libdir"  ]] || { echo "lldb/lib missing in vsix ($libdir)" >&2; exit 1; }

# 3. Find the exact liblldb load path the adapter links against; our dylib must
#    sit at that filename inside extension/lldb/lib so dyld resolves it.
need="$(otool -L "$adapter" | awk '/liblldb.*\.dylib/{print $1; exit}')"
if [[ -z "$need" ]]; then
  shipped="$(/usr/bin/find "$libdir" -maxdepth 1 -name 'liblldb*.dylib' | head -1)"
  need="@rpath/$(basename "$shipped")"
fi
needbase="$(basename "$need")"
echo ">> adapter links: $need  (placing our dylib as $needbase)"

# 4. Drop codelldb's liblldb(s) and drop ours in under the expected name + id.
/usr/bin/find "$libdir" -maxdepth 1 -name 'liblldb*.dylib' -delete
cp "$LIBLLDB" "$libdir/$needbase"
chmod u+w "$libdir/$needbase"
install_name_tool -id "$need" "$libdir/$needbase"

# 5. Ad-hoc re-sign. Signing the adapter too (without hardened runtime) drops
#    library validation, so it will load our ad-hoc-signed dylib.
codesign --remove-signature "$libdir/$needbase" 2>/dev/null || true
codesign --force --sign - "$libdir/$needbase"
codesign --force --sign - "$adapter" 2>/dev/null || true

echo ">> linkage after swap:"
otool -L "$adapter" | grep -i lldb || true
codesign --verify --verbose "$libdir/$needbase" 2>&1 | sed 's/^/   /' || true

echo ">> repackaged codelldb at: $OUTDIR"
echo ">> point provision-toolchain.sh at it with CODELLDB_DIST=$OUTDIR"
echo ">> NOTE: if downloaded via a browser, clear quarantine first:"
echo ">>   xattr -dr com.apple.quarantine \"$OUTDIR\""
