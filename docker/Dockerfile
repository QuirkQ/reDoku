# docker/Dockerfile
# Build environment: Toltec's reMarkable cross toolchain plus what mruby's
# rake-based build needs on the host side (CRuby, native gcc, bison/gperf
# for a git checkout of mruby). xxd is a hard configure-time requirement
# of rM2-stuff (vendor/noto font embedding), used by `make rm2fb`.
FROM ghcr.io/toltec-dev/base:v4.0

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ruby rake bison gperf git file xxd \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /mruby
