# docker/Dockerfile
# Build environment: Toltec's reMarkable cross toolchain plus what mruby's
# rake-based build needs on the host side (CRuby, native gcc, bison/gperf
# for a git checkout of mruby).
FROM ghcr.io/toltec-dev/base:v4.0

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ruby rake bison gperf git file \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /mruby
