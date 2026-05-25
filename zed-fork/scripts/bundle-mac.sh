#!/usr/bin/env bash
# Build Zed GNAT for macOS and produce a self-contained .app.
#
# Reads upstream Zed from the subtree at zed-fork/zed/. There is no
# fetch/patch step: every change we want is already committed to the
# subtree.
#
# Steps:
#   1. Build Zed via its own bundle-mac script (which produces .app).
#   2. Inject the GNAT toolchain (ALS, gnatprove, gprbuild, rflx) into
#      Contents/Resources/tools/.
#   3. Drop a launcher shim into Contents/MacOS/ that exports
#      ZED_GNAT_RESOURCES + PATH so the bundled tools take precedence.
#   4. Code-sign if SIGNING_IDENTITY is set, otherwise produce an unsigned
#      bundle (suitable for ad-hoc local use).
#
# Required env (with sensible defaults):
#   TARGET_TRIPLE       e.g. aarch64-apple-darwin or x86_64-apple-darwin
#   RELEASE_CHANNEL     stable|preview|nightly|dev  (default: stable)
#   TOOLCHAIN_DIR       absolute path to a prepared GNAT toolchain (see
#                       scripts/provision-toolchain.sh). Required.
#   SIGNING_IDENTITY    Apple Developer ID name (optional)
#   APPLE_ID / APPLE_PASS / APPLE_TEAM_ID
#                       Notarization credentials (optional)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZED="${ROOT}/zed"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-stable}"
TARGET_TRIPLE="${TARGET_TRIPLE:-$(rustc -vV | awk '/host:/ {print $2}')}"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "bundle-mac.sh only runs on macOS (got: $(uname -s))" >&2
    exit 1
fi

if [[ -z "${TOOLCHAIN_DIR:-}" ]]; then
    echo "TOOLCHAIN_DIR is required. Run scripts/provision-toolchain.sh first." >&2
    exit 2
fi

# Stamp the release channel.
echo "${RELEASE_CHANNEL}" > "${ZED}/crates/zed/RELEASE_CHANNEL"

pushd "${ZED}" >/dev/null
    # Zed's own bundler will install cargo-bundle if missing.
    #
    # Its final step packages a .dmg (hdiutil create) and runs a slow global
    # `npm install dmg-license`. We discard that DMG: the .app is moved back out
    # below and gets the GNAT toolchain injected, so a distribution DMG would
    # have to be rebuilt after injection anyway. The .app is fully built and
    # signed *before* the DMG step, and hdiutil is flaky on hosted runners
    # ("hdiutil: create failed - Resource busy"), so a DMG-stage failure must not
    # fail our build. Tolerate a non-zero exit here and let the .app-existence
    # check below tell a harmless DMG flake (.app present) apart from a real
    # build failure (no .app -> we still exit non-zero).
    bundle_status=0
    ./script/bundle-mac "${TARGET_TRIPLE}" || bundle_status=$?
    if [[ "${bundle_status}" -ne 0 ]]; then
        echo "upstream bundle-mac exited ${bundle_status}; checking for the .app before treating it as a (discarded) DMG-stage flake" >&2
    fi
popd >/dev/null

APP_NAME="Zed GNAT"
case "${RELEASE_CHANNEL}" in
    stable)   APP_NAME="Zed GNAT" ;;
    preview)  APP_NAME="Zed GNAT Preview" ;;
    nightly)  APP_NAME="Zed GNAT Nightly" ;;
    dev)      APP_NAME="Zed GNAT Dev" ;;
esac

BUNDLE_DIR="${ZED}/target/${TARGET_TRIPLE}/release/bundle/osx"
APP="${BUNDLE_DIR}/${APP_NAME}.app"

# Upstream `zed/script/bundle-mac` moves the .app from bundle/osx/ into
# target/${triple}/release/dmg/ as part of DMG creation, then builds the DMG
# in target/${triple}/release/Zed-${arch}.dmg. We need the .app back in
# bundle/osx/ so we can inject the GNAT toolchain into it (and so the CI
# workflow's archive step finds it). The DMG that upstream just produced is
# stale (no GNAT toolchain) and we ignore it; a fresh DMG, if we ever want
# one for distribution, must be built after toolchain injection.
DMG_STAGING="${ZED}/target/${TARGET_TRIPLE}/release/dmg/${APP_NAME}.app"
if [[ ! -d "${APP}" && -d "${DMG_STAGING}" ]]; then
    echo "Moving .app back from DMG staging dir to ${BUNDLE_DIR}"
    mkdir -p "${BUNDLE_DIR}"
    mv "${DMG_STAGING}" "${APP}"
fi

if [[ ! -d "${APP}" ]]; then
    echo "expected ${APP} after bundle-mac; got:" >&2
    ls -la "${BUNDLE_DIR}" >&2 || true
    ls -la "$(dirname "${DMG_STAGING}")" >&2 || true
    exit 3
fi

RESOURCES="${APP}/Contents/Resources"
TOOLS_DIR="${RESOURCES}/tools"
mkdir -p "${TOOLS_DIR}"

echo "Injecting toolchain from ${TOOLCHAIN_DIR}"
if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "${TOOLCHAIN_DIR}/" "${TOOLS_DIR}/"
else
    rm -rf "${TOOLS_DIR}"
    cp -a "${TOOLCHAIN_DIR}" "${TOOLS_DIR}"
fi

# Launcher: wraps the real Zed binary so the bundled tools win on PATH.
MACOS_DIR="${APP}/Contents/MacOS"
ORIGINAL="${MACOS_DIR}/zed"
WRAPPED="${MACOS_DIR}/zed-real"
LAUNCHER="${MACOS_DIR}/zed"

if [[ ! -f "${WRAPPED}" ]]; then
    mv "${ORIGINAL}" "${WRAPPED}"
fi

cat > "${LAUNCHER}" <<'LAUNCH'
#!/bin/bash
# Zed GNAT launcher. Prepends the bundled toolchain to PATH and exports a
# few env vars consumed by the Ada extension and its LSP wrappers.
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_RESOURCES="$(cd "${HERE}/../Resources" && pwd)"

export ZED_GNAT_RESOURCES="${APP_RESOURCES}"
export PATH="${APP_RESOURCES}/tools/bin:${PATH:-/usr/bin:/bin}"

if [[ -d "${APP_RESOURCES}/tools/lib" ]]; then
    export DYLD_FALLBACK_LIBRARY_PATH="${APP_RESOURCES}/tools/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}"
fi

if [[ -d "${APP_RESOURCES}/tools/python" ]]; then
    export PYTHONPATH="${APP_RESOURCES}/tools/python:${PYTHONPATH:-}"
fi

exec "${HERE}/zed-real" "$@"
LAUNCH
chmod +x "${LAUNCHER}"

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    echo "Signing ${APP} with ${SIGNING_IDENTITY}"
    codesign --force --options runtime --timestamp \
        --entitlements "${ROOT}/bundle/entitlements.plist" \
        --sign "${SIGNING_IDENTITY}" --deep "${APP}"
    if [[ -n "${APPLE_ID:-}" && -n "${APPLE_PASS:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
        DMG="${BUNDLE_DIR}/${APP_NAME}.dmg"
        hdiutil create -volname "${APP_NAME}" -srcfolder "${APP}" -ov -format UDZO "${DMG}"
        xcrun notarytool submit "${DMG}" \
            --apple-id "${APPLE_ID}" --password "${APPLE_PASS}" --team-id "${APPLE_TEAM_ID}" \
            --wait
        xcrun stapler staple "${DMG}"
        xcrun stapler staple "${APP}"
        echo "Notarized DMG at ${DMG}"
    fi
fi

echo
echo "Built: ${APP}"
du -sh "${APP}"
