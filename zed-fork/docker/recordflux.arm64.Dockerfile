# RecordFlux container — Linux/arm64, single-stage (transports-spark, verbatim).
#
# Kept as the validated reference build. recordflux.Dockerfile is a multi-stage
# slimming of this one (same builder steps) and is what the bundled rflx shim
# uses; this single-stage version is handy for debugging the build itself.
#
# Follows the RecordFlux dev guide build path:
#   make install_gnat
#   eval `make printenv_gnat`
#   make install
#
# Ubuntu 24.04 arm64 — native on Apple Silicon. The dev guide pins
# Alire 2.0.1 (no arm64 binary) but 2.1.0 ships an aarch64-linux build
# and needs glibc 2.38 (24.04 ships 2.39; 22.04's 2.35 is too old).
# linux/amd64 via Rosetta isn't viable: gcc segfaults compiling
# langkit_support .adb files even at -j 1.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

#  Build prerequisites — no apt gnat / gnatcoll. Alire provides
#  matching, encapsulation-friendly versions via `make install_gnat`.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        git \
        unzip \
        make \
        libgmp-dev \
        graphviz \
        dnsmasq \
        python3 \
        python3-venv \
        python3-pip \
    && rm -rf /var/lib/apt/lists/*

#  Alire 2.1.0 — closest arm64-compatible to the 2.0.1 the dev guide
#  pins.
ARG ALIRE_VERSION=2.1.0
RUN curl -fL "https://github.com/alire-project/alire/releases/download/v${ALIRE_VERSION}/alr-${ALIRE_VERSION}-bin-aarch64-linux.zip" \
        -o /tmp/alr.zip \
 && unzip /tmp/alr.zip -d /opt/alire \
 && rm /tmp/alr.zip
ENV PATH=/opt/alire/bin:${PATH}

#  Rust 1.77 — pinned per the user guide.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -q -y --profile default --default-toolchain 1.77
ENV PATH=/root/.cargo/bin:${PATH}

#  Node.js 20 — required by the dev guide.
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

#  Poetry — RecordFlux's Makefile uses it for the Python side.
RUN curl -sSL https://install.python-poetry.org | python3 -
ENV PATH=/root/.local/bin:${PATH}

#  Clone RecordFlux source at a pinned tag.
ARG RECORDFLUX_VERSION=0.26.0
RUN git clone --depth 1 --branch v${RECORDFLUX_VERSION} \
        https://github.com/AdaCore/RecordFlux.git /opt/rflx-src

WORKDIR /opt/rflx-src

#  Patch the Makefile:
#  - Drop `rapidflux_devel` from `install`'s deps (we don't need the
#    coverage/audit/mutation cargo tools).
#  - Add `libgpr` to install_gnat's `alr -n with` list — gnatcoll's
#    `gnatcoll_projects.gpr` does `with "gpr";` and the default
#    deps don't pull libgpr transitively.
RUN sed -i 's/^install: $(RFLX) rapidflux_devel$/install: $(RFLX)/' Makefile \
 && sed -i 's/-n with aunit gnatcoll_iconv gnatcoll_gmp/-n with aunit gnatcoll_iconv gnatcoll_gmp libgpr/' Makefile

#  Canonical dev-guide build sequence. The Makefile defaults to
#  FSF_GNAT_VERSION=14.1.3 / GPRBUILD_VERSION=22.0.1, which Alire 2.1.0
#  flags as incompatible with its current crate index. Override to
#  versions Alire 2.1.0 ships and resolves cleanly.
RUN make install_gnat FSF_GNAT_VERSION=15.2.1 GPRBUILD_VERSION=25.0.1

#  Alire 2.1.0's `printenv` only adds `<gnatcoll>/core` to
#  GPR_PROJECT_PATH, but the gnatcoll release tree has its umbrella
#  gnatcoll.gpr at the root and gnatcoll_projects.gpr in `projects/`,
#  both of which librflxlang transitively imports. Add every
#  gnatcoll* dir that contains a .gpr (skipping testsuite/examples
#  noise) to the path before invoking make.
RUN eval "$(make printenv_gnat)" \
 && EXTRA=$(find /root/.local/share/alire/builds -name '*.gpr' \
              -path '*/gnatcoll*' \
              -not -path '*/testsuite/*' \
              -not -path '*/examples/*' \
              -exec dirname {} \; | sort -u | tr '\n' ':') \
 && export GPR_PROJECT_PATH="${EXTRA}${GPR_PROJECT_PATH}" \
 && make -j 6 install
#  Smoke test: rflx loads and reports its version. The full
#  `make test` suite has known root-env failures (permission tests
#  can't fail when run as root in Docker); run those separately
#  outside the build via scripts/rflx-test if needed.
RUN /opt/rflx-src/.venv/bin/rflx --version

ENV PATH=/opt/rflx-src/.venv/bin:${PATH}
WORKDIR /workspace
