# RecordFlux container — amd64 variant for Apple `container` CLI.
#
# Follows RecordFlux's dev guide:
#   make install_gnat
#   eval `make printenv_gnat`
#   make install
#
# Versions match the docs verbatim: Ubuntu 22.04 + Alire 2.0.1.
# Built/run via Apple `container` (Apple Silicon's native Linux
# container runtime, which handles amd64 emulation differently from
# Docker Desktop's Rosetta — verified to handle Ada cross-compilation
# without the gcc ICE we hit on Docker/Rosetta).
#
# Build:  container build --platform linux/amd64 -c 6 -m 8G \
#             -t transports-spark/rflx:amd64 -f Dockerfile.amd64 .
# Run:    container run --rm --platform linux/amd64 \
#             -v $REPO:/workspace transports-spark/rflx:amd64 rflx ...

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

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

#  Alire 2.0.1 — exact version pinned by RecordFlux dev guide.
ARG ALIRE_VERSION=2.0.1
RUN curl -fL "https://github.com/alire-project/alire/releases/download/v${ALIRE_VERSION}/alr-${ALIRE_VERSION}-bin-x86_64-linux.zip" \
        -o /tmp/alr.zip \
 && unzip /tmp/alr.zip -d /opt/alire \
 && rm /tmp/alr.zip
ENV PATH=/opt/alire/bin:${PATH}

#  Rust 1.77 — pinned per the user guide.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -q -y --profile default \
        --target x86_64-unknown-linux-gnu \
        --default-toolchain 1.77
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

#  Patch Makefile:
#  - Drop rapidflux_devel from install (no need for cargo dev tools).
#  - Add libgpr to install_gnat's `alr -n with` (gnatcoll_projects.gpr
#    needs `gpr.gpr`).
RUN sed -i 's/^install: $(RFLX) rapidflux_devel$/install: $(RFLX)/' Makefile \
 && sed -i 's/-n with aunit gnatcoll_iconv gnatcoll_gmp/-n with aunit gnatcoll_iconv gnatcoll_gmp libgpr/' Makefile

#  Build sequence. Use the Makefile's default version pins
#  (FSF_GNAT_VERSION=14.1.3, GPRBUILD_VERSION=22.0.1) — Alire 2.0.1
#  ships these. Alire 2.0.1's `printenv` only puts `<gnatcoll>/core`
#  on GPR_PROJECT_PATH; gnatcoll's umbrella .gpr and `projects/`,
#  `minimal/` subdirs aren't on the path, so prepend them ourselves.
RUN make install_gnat
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
