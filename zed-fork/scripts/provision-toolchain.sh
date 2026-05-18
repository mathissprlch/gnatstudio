#!/usr/bin/env bash
# Stage a self-contained GNAT/SPARK/RecordFlux toolchain under
# $TOOLCHAIN_DIR/{bin,lib,share,python} so bundle-mac.sh can drop it
# into the .app's Resources/tools/.
#
# Strategy: lean on Alire (`alr install --prefix=...`) for the Ada side
# of the world. RecordFlux is a Python package, so it goes into a
# vendored venv. Anything Alire can't provide (e.g. `gnatprove` on
# platforms where the FSF SPARK crate is unavailable) is left out --
# the launcher just won't find it and the user can install it manually.
#
# Outputs:
#   $TOOLCHAIN_DIR/bin     gnat, gprbuild, ada_language_server, gnatprove,
#                          rflx, gdb (if available), python3
#   $TOOLCHAIN_DIR/lib     shared libs + GNAT runtime
#   $TOOLCHAIN_DIR/share   runtime files
#   $TOOLCHAIN_DIR/python  vendored RecordFlux venv
#
# The script is idempotent and prints what it skipped.
set -euo pipefail

TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-${PWD}/build/toolchain}"
ALIRE_VERSION="${ALIRE_VERSION:-2.0.2}"

mkdir -p "${TOOLCHAIN_DIR}/bin"

log()  { printf '== %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------

install_alire_if_needed() {
    if command -v alr >/dev/null 2>&1; then
        log "alr already on PATH: $(command -v alr) ($(alr --version 2>/dev/null | head -1))"
        return 0
    fi

    local os arch asset
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"
    case "${os}-${arch}" in
        darwin-arm64)  asset="alr-${ALIRE_VERSION}-bin-aarch64-macos.zip" ;;
        darwin-x86_64) asset="alr-${ALIRE_VERSION}-bin-x86_64-macos.zip"  ;;
        linux-x86_64)  asset="alr-${ALIRE_VERSION}-bin-x86_64-linux.zip"  ;;
        *)
            warn "no prebuilt Alire binary for ${os}-${arch}"
            return 2
            ;;
    esac

    local url="https://github.com/alire-project/alire/releases/download/v${ALIRE_VERSION}/${asset}"
    local tmp
    tmp="$(mktemp -d)"
    log "downloading ${url}"
    curl --fail --silent --show-error --location --output "${tmp}/alr.zip" "${url}"
    (cd "${tmp}" && unzip -q alr.zip)
    install -m 0755 "${tmp}/bin/alr" "${TOOLCHAIN_DIR}/bin/alr"
    rm -rf "${tmp}"

    export PATH="${TOOLCHAIN_DIR}/bin:${PATH}"
    log "installed alr at ${TOOLCHAIN_DIR}/bin/alr"
}

# `alr install --prefix=DIR <crate>` is the supported way (Alire 2.x) to drop
# a binary crate into a freestanding tree of bin/, lib/, share/.
alr_install() {
    local crate="$1"
    log "alr install --prefix=${TOOLCHAIN_DIR} ${crate}"
    if alr -n install --prefix="${TOOLCHAIN_DIR}" "${crate}"; then
        return 0
    fi
    warn "alr install ${crate} failed; the bundle will be missing this tool"
    return 0   # don't break the build for one missing crate
}

# Select the FSF GNAT + gprbuild toolchain that Alire will resolve against.
select_default_toolchain() {
    log "selecting default Alire toolchain (gnat_native + gprbuild)"
    alr -n toolchain --select gnat_native gprbuild
}

# ---------------------------------------------------------------------------

install_recordflux() {
    local py
    py="$(command -v python3.12 || command -v python3.11 || command -v python3 || true)"
    if [[ -z "${py}" ]]; then
        warn "no python3 found; skipping RecordFlux"
        return 0
    fi

    if [[ ! -x "${TOOLCHAIN_DIR}/python/bin/pip" ]]; then
        log "creating Python venv at ${TOOLCHAIN_DIR}/python"
        "${py}" -m venv "${TOOLCHAIN_DIR}/python"
    fi

    "${TOOLCHAIN_DIR}/python/bin/pip" install --quiet --upgrade pip wheel
    if ! "${TOOLCHAIN_DIR}/python/bin/pip" install --quiet "RecordFlux>=0.25"; then
        warn "pip install RecordFlux failed; the bundle will be missing rflx"
        return 0
    fi

    if [[ -f "${TOOLCHAIN_DIR}/python/bin/rflx" ]]; then
        ln -sf "${TOOLCHAIN_DIR}/python/bin/rflx" "${TOOLCHAIN_DIR}/bin/rflx"
    fi
    if [[ -f "${TOOLCHAIN_DIR}/python/bin/python3" ]]; then
        ln -sf "${TOOLCHAIN_DIR}/python/bin/python3" "${TOOLCHAIN_DIR}/bin/python3"
    fi
}

main() {
    if ! command -v curl  >/dev/null 2>&1; then warn "curl is required"; exit 1; fi
    if ! command -v unzip >/dev/null 2>&1; then warn "unzip is required"; exit 1; fi

    install_alire_if_needed
    select_default_toolchain

    # FSF GNAT compiler (gnat, gnatmake, gnatbind, gnatlink, ...) and the
    # GNAT runtime libs. `gnat_native` is the toolchain crate; `alr install`
    # writes its bin/lib/share into ${TOOLCHAIN_DIR}.
    alr_install gnat_native
    alr_install gprbuild
    alr_install ada_language_server
    # spark2014 is published as a crate on Alire's community index; if it's
    # missing on this platform alr_install just logs a warning.
    alr_install spark2014

    install_recordflux

    log "Staged toolchain at ${TOOLCHAIN_DIR}"
    if [[ -d "${TOOLCHAIN_DIR}/bin" ]]; then
        log "Binaries:"
        ls "${TOOLCHAIN_DIR}/bin" | sed 's/^/  /'
    fi
    du -sh "${TOOLCHAIN_DIR}"
}

main "$@"
