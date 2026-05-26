# RecordFlux (rflx) -- minimal linux/amd64 image (prebuilt wheel via uv).
#
# Built locally by the `rflx` shim on first use (or loaded from a vendored
# tarball if present). Two stages keep the runtime image lean:
#   1. builder: install RecordFlux into a self-contained venv via uv (fast,
#      Rust-based pip replacement -- no pip/setuptools/wheel residue).
#   2. final:   copy just the venv onto a fresh python:3.12-slim.
#
# Result: ~200 MB (vs ~250 MB with pip), and the wheel install drops from
# ~30-60s to ~5s. No GNAT/Rust/langkit source build -- RecordFlux publishes
# x86_64 manylinux wheels; this image runs under Docker's amd64 emulation on
# Apple Silicon, which is fine for the prebuilt CLI (the gcc ICE we hit under
# emulation was a *build*-time problem, avoided entirely here).
#
# Alpine is intentionally not used: RecordFlux ships only manylinux (glibc)
# wheels -- on musl pip would fall back to the sdist and rebuild the whole
# GNAT/Rust/langkit stack, the multi-GB nightmare this image exists to avoid.
#
# For a native arm64 image (no emulation) see recordflux.arm64.Dockerfile --
# that is the from-source build, since RecordFlux ships no arm64 wheel.

# --- builder: install RecordFlux into /opt/venv via uv ---------------------
FROM --platform=linux/amd64 python:3.12-slim AS builder

# Bump to move RecordFlux versions. The rflx shim reads this line to tag the
# image, so changing it rebuilds on next use.
ARG RECORDFLUX_VERSION=0.26.0

ENV VIRTUAL_ENV=/opt/venv \
    UV_NO_CACHE=1

RUN pip install --no-cache-dir uv \
 && uv venv "${VIRTUAL_ENV}" \
 && uv pip install "RecordFlux==${RECORDFLUX_VERSION}" \
 && find "${VIRTUAL_ENV}" -depth -type d -name __pycache__ -exec rm -rf {} + \
 && find "${VIRTUAL_ENV}" -depth -type d -name tests -exec rm -rf {} +

# --- final: just python + the venv, no uv/pip residue ---------------------
FROM --platform=linux/amd64 python:3.12-slim
COPY --from=builder /opt/venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
WORKDIR /workspace
ENTRYPOINT ["rflx"]
