#!/usr/bin/env bash
# Heavy GNAT toolchain provisioning -- the ~80% of `make toolchain` cost:
# Alire bootstrap, FSF toolchain selection (gnat_native + gprbuild), and crate
# installs of ada_language_server + spark2014.
#
# This script is the one the CI toolchain cache key hashes (see
# .github/workflows/zed-gnat-mac.yml). Keeping it isolated from the
# fast-iterating bits (rflx shim, codelldb sourcing, Python venv -- now in
# provision-toolchain.sh) means edits to those don't bust the multi-GB Alire
# output cache. Adding/removing a crate here is the only edit that should.
#
# Sourced by provision-toolchain.sh; can also run standalone with
# TOOLCHAIN_DIR=... bash provision-gnat.sh.
set -euo pipefail

: "${TOOLCHAIN_DIR:?TOOLCHAIN_DIR must be set}"
: "${ALIRE_VERSION:=2.0.2}"

mkdir -p "${TOOLCHAIN_DIR}/bin"
# Make sure a restored alr from the toolchain cache wins over any system one.
export PATH="${TOOLCHAIN_DIR}/bin:${PATH}"

# Shared helpers -- consumed by the orchestrator too.
log()  { printf '== %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }

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

# Single entry point invoked by the orchestrator. Adding/removing a crate
# here is the only edit that should bust the toolchain cache.
install_gnat_core() {
    install_alire_if_needed
    select_default_toolchain

    # FSF GNAT compiler (gnat, gnatmake, gnatbind, gnatlink, ...) and runtime.
    alr_install gnat_native
    alr_install gprbuild
    alr_install ada_language_server
    # spark2014 is on Alire's community index; if it's missing on this platform
    # alr_install just logs a warning and the bundle ships without it.
    alr_install spark2014
}

# Allow standalone invocation.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_gnat_core
fi
