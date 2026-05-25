#!/usr/bin/env bash
# Stage a self-contained GNAT/SPARK/RecordFlux toolchain under
# $TOOLCHAIN_DIR/{bin,lib,share,python} so bundle-mac.sh can drop it
# into the .app's Resources/tools/.
#
# Strategy: lean on Alire (`alr install --prefix=...`) for the Ada side
# of the world. RecordFlux has no macOS wheel and a heavy from-source
# build, so `rflx` is staged as a Docker-backed shim (see docker/) that
# runs RecordFlux in a Linux container; a bundled python3 is kept for the
# stdlib-only LSP servers. Anything Alire can't provide (e.g. `gnatprove`
# where the FSF SPARK crate is unavailable) is left out -- the launcher
# just won't find it and the user can install it manually.
#
# Outputs:
#   $TOOLCHAIN_DIR/bin     gnat, gprbuild, ada_language_server, gnatprove,
#                          rflx, gdb (if available), python3
#   $TOOLCHAIN_DIR/lib     shared libs + GNAT runtime
#   $TOOLCHAIN_DIR/share   runtime files (+ recordflux/ Dockerfile & shim data)
#   $TOOLCHAIN_DIR/python  vendored python3 (for the LSP servers)
#
# The script is idempotent and prints what it skipped.
set -euo pipefail

TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-${PWD}/build/toolchain}"
ALIRE_VERSION="${ALIRE_VERSION:-2.0.2}"
CODELLDB_VERSION="${CODELLDB_VERSION:-v1.11.5}"

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
    # A bundled python3 for the stdlib-only LSP servers (proof + RecordFlux).
    local py
    py="$(command -v python3.12 || command -v python3.11 || command -v python3 || true)"
    if [[ -n "${py}" && ! -x "${TOOLCHAIN_DIR}/python/bin/python3" ]]; then
        log "creating Python venv at ${TOOLCHAIN_DIR}/python (for the LSP servers)"
        "${py}" -m venv "${TOOLCHAIN_DIR}/python" \
            || warn "venv creation failed; LSP servers will need a system python3"
    fi
    if [[ -f "${TOOLCHAIN_DIR}/python/bin/python3" ]]; then
        ln -sf "../python/bin/python3" "${TOOLCHAIN_DIR}/bin/python3"
    fi

    # rflx itself: RecordFlux ships no macOS/arm64 wheel and a from-source build
    # needs a full GNAT+GNATColl+GMP toolchain, so run it in a Linux container.
    # Stage the vendored Dockerfile and an `rflx` shim that builds the image on
    # first use (Docker assumed present on the host). The shim is a drop-in for
    # the `rflx` the LSP invokes.
    local dockerfile_src share_dir
    dockerfile_src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docker/recordflux.Dockerfile"
    share_dir="${TOOLCHAIN_DIR}/share/recordflux"
    if [[ ! -f "${dockerfile_src}" ]]; then
        warn "recordflux.Dockerfile not found at ${dockerfile_src}; rflx unavailable"
        return 0
    fi
    mkdir -p "${share_dir}"
    cp "${dockerfile_src}" "${share_dir}/recordflux.Dockerfile"

    cat > "${TOOLCHAIN_DIR}/bin/rflx" <<'RFLX'
#!/usr/bin/env bash
# Docker-backed RecordFlux CLI (rflx).
#
# RecordFlux has no macOS wheel, so Zed GNAT runs it in a Linux container. The
# image is resolved in this order, so the same shim works whether or not a
# prebuilt image was vendored into the bundle:
#   1. already present in Docker        -> use it
#   2. vendored image tarball alongside -> docker load it (no build)
#   3. otherwise                        -> docker build from the Dockerfile
# Docker is assumed installed on the host. Drop-in for the rflx the LSP calls:
# the current directory is bind-mounted at the same path so file arguments and
# the generate output directory resolve identically inside the container.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
share="$(cd "${here}/../share/recordflux" 2>/dev/null && pwd || true)"

if ! command -v docker >/dev/null 2>&1; then
  cat >&2 <<'MSG'
rflx: Docker is required to run RecordFlux on this platform (RecordFlux ships no
      macOS wheel). Install Docker Desktop, OrbStack, or colima, make sure
      `docker` is on PATH, and retry.
MSG
  exit 127
fi

if [ -z "${share}" ]; then
  echo "rflx: vendored RecordFlux assets not found next to this shim" >&2
  exit 1
fi

version="$(sed -n 's/^ARG RECORDFLUX_VERSION=//p' "${share}/recordflux.Dockerfile" 2>/dev/null | head -n1)"
image="zed-gnat/recordflux:${version:-latest}"

if ! docker image inspect "${image}" >/dev/null 2>&1; then
  if [ -f "${share}/recordflux-image.tar.gz" ]; then
    echo "rflx: loading bundled RecordFlux image (first run only)..." >&2
    gunzip -c "${share}/recordflux-image.tar.gz" | docker load >&2
  elif [ -f "${share}/recordflux.Dockerfile" ]; then
    echo "rflx: building ${image} from the vendored Dockerfile (first run; this takes a while)..." >&2
    docker build -q -t "${image}" -f "${share}/recordflux.Dockerfile" "${share}" >&2
  else
    echo "rflx: no bundled image tarball or Dockerfile found in ${share}" >&2
    exit 1
  fi
fi

workdir="$(pwd)"
exec docker run --rm \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp \
  --volume "${workdir}:${workdir}" \
  --workdir "${workdir}" \
  "${image}" "$@"
RFLX
    chmod +x "${TOOLCHAIN_DIR}/bin/rflx"
    log "staged Docker-backed rflx (vendored image if present, else built on first use)"
}

# Bundle the codelldb DAP adapter so the GNAT/codelldb debug scenarios can
# actually launch from the shipped .app. Stock codelldb gives working
# breakpoints/stepping/registers; Ada *variable* rendering needs a patched
# liblldb (see patches/README.md). CI can inject a patched build by setting
# CODELLDB_DIST to a directory or .vsix; otherwise we fetch the upstream
# release. Failures are tolerated so a codelldb hiccup never breaks the app.
bundle_codelldb() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        return 0
    fi
    local dest="${TOOLCHAIN_DIR}/codelldb"
    local adapter="${dest}/extension/adapter/codelldb"

    link_adapter() {
        if [[ -x "${adapter}" ]]; then
            chmod +x "${adapter}" 2>/dev/null || true
            ln -sf "../codelldb/extension/adapter/codelldb" "${TOOLCHAIN_DIR}/bin/codelldb"
            log "staged codelldb -> ${TOOLCHAIN_DIR}/bin/codelldb"
            return 0
        fi
        return 1
    }

    if link_adapter; then
        log "codelldb already staged at ${dest}"
        return 0
    fi

    mkdir -p "${dest}"

    # CI-injected patched build (directory tree or .vsix zip).
    if [[ -n "${CODELLDB_DIST:-}" ]]; then
        log "using CODELLDB_DIST=${CODELLDB_DIST}"
        if [[ -d "${CODELLDB_DIST}" ]]; then
            cp -a "${CODELLDB_DIST}/." "${dest}/"
        elif [[ -f "${CODELLDB_DIST}" ]]; then
            (cd "${dest}" && unzip -q "${CODELLDB_DIST}") || warn "failed to unzip CODELLDB_DIST"
        else
            warn "CODELLDB_DIST=${CODELLDB_DIST} not found"
        fi
        link_adapter || warn "codelldb adapter missing after CODELLDB_DIST install"
        return 0
    fi

    local arch
    case "$(uname -m)" in
        arm64|aarch64) arch="arm64" ;;
        x86_64)        arch="x64"   ;;
        *) warn "no codelldb mapping for arch $(uname -m); skipping"; return 0 ;;
    esac

    local base="https://github.com/vadimcn/codelldb/releases/download/${CODELLDB_VERSION}"
    # Asset naming changed across releases; try modern then legacy forms.
    local names=("codelldb-darwin-${arch}.vsix")
    case "${arch}" in
        arm64) names+=("codelldb-aarch64-darwin.vsix") ;;
        x64)   names+=("codelldb-x86_64-darwin.vsix")  ;;
    esac

    local tmp got=""
    tmp="$(mktemp -d)"
    local n
    for n in "${names[@]}"; do
        log "downloading ${base}/${n}"
        if curl --fail --silent --show-error --location --output "${tmp}/codelldb.vsix" "${base}/${n}"; then
            got="yes"; break
        fi
    done
    if [[ -z "${got}" ]]; then
        warn "could not download codelldb ${CODELLDB_VERSION}; the bundle will have no debug adapter"
        rm -rf "${tmp}"; return 0
    fi
    if ! (cd "${dest}" && unzip -q "${tmp}/codelldb.vsix"); then
        warn "failed to extract codelldb vsix; skipping"
        rm -rf "${tmp}"; return 0
    fi
    rm -rf "${tmp}"

    link_adapter || warn "codelldb adapter binary not found after extraction"
}

# Alire-staged binaries carry LC_RPATH entries that point to the build
# machine's Alire toolchain dir (e.g. /Users/runner/.local/share/alire/...).
# When the toolchain is dropped into a user's .app, dyld either fails to
# find the libs at that path or — worse on Sonoma+ — rejects the binary
# outright because alr install duplicates the LC_RPATH. Rewrite the
# rpaths to use @loader_path so the binaries find their dylibs at the
# bundle-relative ../lib regardless of where the .app lives.
relocate_macho() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        return 0
    fi
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    log "Relocating Mach-O binaries under ${TOOLCHAIN_DIR}"
    python3 "${script_dir}/relocate-toolchain.py" "${TOOLCHAIN_DIR}"
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

    bundle_codelldb

    relocate_macho

    log "Staged toolchain at ${TOOLCHAIN_DIR}"
    if [[ -d "${TOOLCHAIN_DIR}/bin" ]]; then
        log "Binaries:"
        ls "${TOOLCHAIN_DIR}/bin" | sed 's/^/  /'
    fi
    du -sh "${TOOLCHAIN_DIR}"
}

main "$@"
