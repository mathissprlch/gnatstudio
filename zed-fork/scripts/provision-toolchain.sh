#!/usr/bin/env bash
# Stage a self-contained GNAT/SPARK/RecordFlux toolchain under
# $TOOLCHAIN_DIR/{bin,lib,share,python} so bundle-mac.sh can drop it
# into the .app's Resources/tools/.
#
# Strategy: lean on Alire (alr) to fetch reproducible binaries for:
#   - gnat_native       (the FSF GNAT toolchain: gnat, gprbuild, gprclean, gdb)
#   - ada_language_server
#   - spark2014         (gnatprove + provers)
#   - recordflux        (rflx)
#
# Alire is the supported reproducible way to provision these tools; if it
# is not on PATH the script attempts to install it.
#
# Outputs:
#   $TOOLCHAIN_DIR/bin     symlinks/binaries: gnat, gprbuild, ada_language_server,
#                          gnatprove, rflx, gdb, codelldb, python3
#   $TOOLCHAIN_DIR/lib     shared libs needed by the above
#   $TOOLCHAIN_DIR/share   runtime files (ALS schemas, gnatprove configs, etc.)
#   $TOOLCHAIN_DIR/python  vendored RecordFlux + deps (so the bundled python
#                          can `import rflx`)
#
# The script is idempotent and prints what it skipped.
set -euo pipefail

TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-${PWD}/build/toolchain}"
ALIRE_DIR="${ALIRE_DIR:-${TOOLCHAIN_DIR}/.alire}"
mkdir -p "${TOOLCHAIN_DIR}"/{bin,lib,share,python}

need() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required tool: $1" >&2
        return 1
    fi
}

install_alire() {
    if command -v alr >/dev/null 2>&1; then
        return 0
    fi
    case "$(uname -s)" in
        Darwin)
            local ver="2.0.2"
            local arch="$(uname -m)"
            local pkg
            case "${arch}" in
                arm64)   pkg="alr-${ver}-bin-aarch64-macos.zip" ;;
                x86_64)  pkg="alr-${ver}-bin-x86_64-macos.zip"  ;;
                *) echo "unsupported macOS arch: ${arch}" >&2; return 2 ;;
            esac
            local tmp; tmp="$(mktemp -d)"
            curl -fL -o "${tmp}/alr.zip" \
                "https://github.com/alire-project/alire/releases/download/v${ver}/${pkg}"
            (cd "${tmp}" && unzip -q alr.zip)
            install -m 0755 "${tmp}/bin/alr" "${TOOLCHAIN_DIR}/bin/alr"
            export PATH="${TOOLCHAIN_DIR}/bin:${PATH}"
            ;;
        Linux)
            local ver="2.0.2"
            local pkg="alr-${ver}-bin-x86_64-linux.zip"
            local tmp; tmp="$(mktemp -d)"
            curl -fL -o "${tmp}/alr.zip" \
                "https://github.com/alire-project/alire/releases/download/v${ver}/${pkg}"
            (cd "${tmp}" && unzip -q alr.zip)
            install -m 0755 "${tmp}/bin/alr" "${TOOLCHAIN_DIR}/bin/alr"
            export PATH="${TOOLCHAIN_DIR}/bin:${PATH}"
            ;;
        *) echo "unsupported OS for alire bootstrap: $(uname -s)" >&2; return 2 ;;
    esac
}

stage_crate() {
    local crate="$1"
    local crate_dir="${ALIRE_DIR}/${crate}"
    if [[ ! -d "${crate_dir}" ]]; then
        mkdir -p "${ALIRE_DIR}"
        (cd "${ALIRE_DIR}" && alr -n init --bin --no-skel "${crate}" >/dev/null)
        (cd "${crate_dir}" && alr -n with "${crate}" >/dev/null)
    fi
    (cd "${crate_dir}" && alr -n update >/dev/null)
    # Drop the resolved binaries into our staging area.
    (cd "${crate_dir}" && alr -n exec -- bash -c "
        for b in \$(alr -n printenv 2>/dev/null | awk -F= '/^export PATH=/{gsub(/\"/,\"\",\$2); print \$2}' | tr ':' '\n' | sort -u); do
            [[ -d \"\$b\" ]] || continue
            find \"\$b\" -maxdepth 1 -type f -perm -u+x -print0 | while IFS= read -r -d '' f; do
                cp -nu \"\$f\" '${TOOLCHAIN_DIR}/bin/' || true
            done
        done
    ")
    # Mirror lib/ and share/ from each pulled crate.
    find "${crate_dir}/alire/cache" -maxdepth 4 -type d \( -name lib -o -name share \) -print0 2>/dev/null \
        | while IFS= read -r -d '' d; do
            base="$(basename "$d")"
            rsync -a "$d"/ "${TOOLCHAIN_DIR}/${base}/"
        done
}

install_recordflux() {
    # RecordFlux is Python; vendor a self-contained venv into python/.
    local py
    py="$(command -v python3.12 || command -v python3.11 || command -v python3 || true)"
    if [[ -z "${py}" ]]; then
        echo "no python3 found; skipping RecordFlux" >&2
        return 0
    fi
    "${py}" -m venv "${TOOLCHAIN_DIR}/python"
    "${TOOLCHAIN_DIR}/python/bin/pip" install --upgrade pip wheel >/dev/null
    "${TOOLCHAIN_DIR}/python/bin/pip" install "RecordFlux>=0.25" >/dev/null
    # Symlink rflx into bin/.
    ln -sf "${TOOLCHAIN_DIR}/python/bin/rflx" "${TOOLCHAIN_DIR}/bin/rflx"
    ln -sf "${TOOLCHAIN_DIR}/python/bin/python3" "${TOOLCHAIN_DIR}/bin/python3"
}

main() {
    need curl
    need unzip
    install_alire

    stage_crate gnat_native
    stage_crate gprbuild
    stage_crate ada_language_server
    stage_crate spark2014
    install_recordflux

    echo
    echo "Staged toolchain at ${TOOLCHAIN_DIR}"
    echo "Binaries:"
    ls "${TOOLCHAIN_DIR}/bin" | sed 's/^/  /'
    du -sh "${TOOLCHAIN_DIR}"
}

main "$@"
