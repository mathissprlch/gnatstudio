#!/usr/bin/env bash
# Build Zed GNAT for macOS and produce a self-contained .app.
#
# Steps:
#   1. Build Zed via its own bundle-mac script (which produces Zed.app).
#   2. Rename the bundle (driven by the branding patch already applied).
#   3. Inject the GNAT toolchain (ALS, gnatprove, gprbuild, rflx) into
#      Contents/Resources/tools/.
#   4. Drop a launcher shim into Contents/MacOS/ that exports
#      ZED_GNAT_RESOURCES + PATH so the bundled tools take precedence.
#   5. Code-sign if SIGNING_IDENTITY is set, otherwise produce an unsigned
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
VENDOR="${ROOT}/vendor/zed"
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
echo "${RELEASE_CHANNEL}" > "${VENDOR}/crates/zed/RELEASE_CHANNEL"

pushd "${VENDOR}" >/dev/null
    # Zed's own bundler will install cargo-bundle if missing.
    ./script/bundle-mac "${TARGET_TRIPLE}"
popd >/dev/null

APP_NAME="Zed GNAT"
case "${RELEASE_CHANNEL}" in
    stable)   APP_NAME="Zed GNAT" ;;
    preview)  APP_NAME="Zed GNAT Preview" ;;
    nightly)  APP_NAME="Zed GNAT Nightly" ;;
    dev)      APP_NAME="Zed GNAT Dev" ;;
esac

# Zed's bundler puts the app under target/<triple>/release/bundle/osx/.
BUNDLE_DIR="${VENDOR}/target/${TARGET_TRIPLE}/release/bundle/osx"
APP="${BUNDLE_DIR}/${APP_NAME}.app"

if [[ ! -d "${APP}" ]]; then
    echo "expected ${APP} after bundle-mac; got:" >&2
    ls "${BUNDLE_DIR}" >&2
    exit 3
fi

RESOURCES="${APP}/Contents/Resources"
TOOLS_DIR="${RESOURCES}/tools"
mkdir -p "${TOOLS_DIR}"

echo "Injecting toolchain from ${TOOLCHAIN_DIR}"
rsync -a --delete "${TOOLCHAIN_DIR}/" "${TOOLS_DIR}/"

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

# Make GNAT's runtime libraries discoverable.
if [[ -d "${APP_RESOURCES}/tools/lib" ]]; then
    export DYLD_FALLBACK_LIBRARY_PATH="${APP_RESOURCES}/tools/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}"
fi

# RecordFlux ships as a Python package; make it importable from the bundled
# python without polluting the user's site-packages.
if [[ -d "${APP_RESOURCES}/tools/python" ]]; then
    export PYTHONPATH="${APP_RESOURCES}/tools/python:${PYTHONPATH:-}"
fi

exec "${HERE}/zed-real" "$@"
LAUNCH
chmod +x "${LAUNCHER}"

# Sign / notarize if credentials are available.
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
