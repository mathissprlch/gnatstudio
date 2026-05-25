# RecordFlux (rflx) — minimal Linux/arm64 image (multi-stage).
#
# RecordFlux has no macOS wheel and no arm64 wheel, so it must be built from
# source; and it must be built *natively* on arm64 -- amd64-under-Rosetta ICEs
# gcc compiling langkit_support (see recordflux.amd64.Dockerfile for the Apple
# `container` CLI variant that emulates amd64 differently).
#
# This is transports-spark's validated arm64 build in the `builder` stage,
# followed by a slim runtime stage that copies only the resulting venv. Because
# librflxlang is built STANDALONE=encapsulated (the GNAT runtime is baked into
# the .so), the runtime needs just python3 + libgmp, not the GNAT/Rust/Node
# build toolchain -- shrinking the image from multiple GB to a few hundred MB,
# small enough to vendor as a prebuilt image.
#
# Built (and optionally `docker save`d for vendoring) on a native arm64 host;
# the bundled `rflx` shim loads a vendored image if present, else builds this.

# ---- builder: transports-spark's validated RecordFlux source build ---------
FROM ubuntu:24.04 AS builder
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl git unzip make \
        libgmp-dev graphviz dnsmasq \
        python3 python3-venv python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Alire 2.1.0 ships an aarch64-linux build and needs glibc 2.38 (24.04 has 2.39).
ARG ALIRE_VERSION=2.1.0
RUN curl -fL "https://github.com/alire-project/alire/releases/download/v${ALIRE_VERSION}/alr-${ALIRE_VERSION}-bin-aarch64-linux.zip" \
        -o /tmp/alr.zip \
 && unzip /tmp/alr.zip -d /opt/alire \
 && rm /tmp/alr.zip
ENV PATH=/opt/alire/bin:${PATH}

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -q -y --profile default --default-toolchain 1.77
ENV PATH=/root/.cargo/bin:${PATH}

RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

RUN curl -sSL https://install.python-poetry.org | python3 -
ENV PATH=/root/.local/bin:${PATH}

ARG RECORDFLUX_VERSION=0.26.0
RUN git clone --depth 1 --branch v${RECORDFLUX_VERSION} \
        https://github.com/AdaCore/RecordFlux.git /opt/rflx-src
WORKDIR /opt/rflx-src

# Drop rapidflux_devel (cargo dev tools we don't need) from `install`, and add
# libgpr to install_gnat's crates (gnatcoll_projects.gpr does `with "gpr";`).
RUN sed -i 's/^install: $(RFLX) rapidflux_devel$/install: $(RFLX)/' Makefile \
 && sed -i 's/-n with aunit gnatcoll_iconv gnatcoll_gmp/-n with aunit gnatcoll_iconv gnatcoll_gmp libgpr/' Makefile

# Override the Makefile's default GNAT/gprbuild pins to versions Alire 2.1.0
# resolves cleanly.
RUN make install_gnat FSF_GNAT_VERSION=15.2.1 GPRBUILD_VERSION=25.0.1

# Alire's printenv only puts <gnatcoll>/core on GPR_PROJECT_PATH; librflxlang
# also imports gnatcoll's umbrella .gpr and projects/, so add every gnatcoll*
# dir that holds a .gpr (minus testsuite/examples noise) before building.
RUN eval "$(make printenv_gnat)" \
 && EXTRA=$(find /root/.local/share/alire/builds -name '*.gpr' \
              -path '*/gnatcoll*' \
              -not -path '*/testsuite/*' \
              -not -path '*/examples/*' \
              -exec dirname {} \; | sort -u | tr '\n' ':') \
 && export GPR_PROJECT_PATH="${EXTRA}${GPR_PROJECT_PATH}" \
 && make -j 6 install
RUN /opt/rflx-src/.venv/bin/rflx --version

# ---- runtime: slim image with only the built venv --------------------------
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# librflxlang is encapsulated (GNAT runtime baked in); the remaining shared
# deps are python3 + libgmp (gnatcoll_gmp). graphviz only if you use
# `rflx graph`; add it here if needed.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 libgmp10 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/rflx-src/.venv /opt/rflx-src/.venv
ENV PATH=/opt/rflx-src/.venv/bin:${PATH}

# Fail the build if the slimmed runtime is missing a shared lib the venv needs.
RUN rflx --version

WORKDIR /workspace
ENTRYPOINT ["rflx"]
