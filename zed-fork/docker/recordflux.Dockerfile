# RecordFlux (rflx) — minimal linux/amd64 image (prebuilt wheel).
#
# This is the image the bundled `rflx` shim uses (pulled from GHCR if published,
# otherwise built here on first use). RecordFlux publishes x86_64 manylinux
# wheels, so this just installs the prebuilt wheel -- no GNAT/Rust/langkit source
# build -- making the image small (~250 MB) and quick to build (~2 min, mostly
# download). On Apple Silicon it runs under Docker's amd64 emulation, which is
# fine for running the prebuilt CLI: the gcc ICE we hit under emulation was a
# *build*-time problem (compiling langkit_support), avoided entirely here.
#
# For a native arm64 image (no emulation) build recordflux.arm64.Dockerfile
# instead -- that is the from-source build, since RecordFlux ships no arm64 wheel.
FROM --platform=linux/amd64 python:3.12-slim

# Bump to move RecordFlux versions. The rflx shim and the GHCR publish workflow
# both read this to tag the image, so changing it repulls/rebuilds on next use.
ARG RECORDFLUX_VERSION=0.26.0
RUN pip install --no-cache-dir "RecordFlux==${RECORDFLUX_VERSION}"

WORKDIR /workspace
ENTRYPOINT ["rflx"]
