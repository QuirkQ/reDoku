# Makefile — every target is a thin Docker wrapper; nothing runs on the Mac.
IMAGE        := redoku-build
# Sibling checkouts are used when they exist; otherwise the pinned
# versions below are cloned into tmp/ (gitignored) on first use.
MRUBY_DIR    ?= $(firstword $(wildcard ../mruby) tmp/mruby)
RM2STUFF_DIR ?= $(firstword $(wildcard ../rM2-stuff) tmp/rM2-stuff)
MRUBY_REF    := 4.0.0
RM2STUFF_REF := 451577081b9eaa3d582e50bbca8c4adfd4911b53
PLATFORM     := linux/amd64

# Pinned SQLite amalgamation for mrbgems/mruby-sqlite3 (M3a Task 0). The
# download-page encoding is 3XXYY00, so 3.53.4 is 3530400; the checksum is
# the SHA3-256 published on https://www.sqlite.org/download.html.
SQLITE_VERSION ?= 3530400
SQLITE_YEAR    ?= 2026
SQLITE_SHA3_256 := 628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e
SQLITE_ZIP     := tmp/sqlite/sqlite-amalgamation-$(SQLITE_VERSION).zip

DOCKER_RUN := docker run --rm --platform $(PLATFORM) \
	-v $(CURDIR):/work \
	-v $(abspath $(MRUBY_DIR)):/mruby \
	-w /mruby $(IMAGE)

RAKE := rake MRUBY_CONFIG=/work/build_config.rb MRUBY_BUILD_DIR=/work/build

.PHONY: image build test test-tools rm2fb sqlite shell clean

image:
	docker build --platform $(PLATFORM) -t $(IMAGE) docker

build: image | $(MRUBY_DIR)
	$(DOCKER_RUN) $(RAKE)

test: image | $(MRUBY_DIR)
	$(DOCKER_RUN) $(RAKE) test

# tools/ is host-side CRuby (stdlib only — bin/redoku install runs it on the
# owner's Mac), not mruby: no gem to build, nothing to cross-compile. This
# only needs the image's plain "ruby", so — unlike `test` above — it does
# NOT depend on $(MRUBY_DIR) or mount it; a bare checkout with no sibling
# mruby/rM2-stuff can still run it.
test-tools: image
	docker run --rm --platform $(PLATFORM) \
		-v $(CURDIR):/work \
		-w /work $(IMAGE) \
		ruby tools/test/mkdecoy_test.rb

tmp/mruby:
	git clone --depth 1 --branch $(MRUBY_REF) https://github.com/mruby/mruby.git $@

tmp/rM2-stuff:
	git clone https://github.com/QuirkQ/rM2-stuff.git $@
	git -C $@ checkout $(RM2STUFF_REF)

# Fetches the pinned SQLite amalgamation into tmp/sqlite/ and verifies the
# SHA3-256 checksum published on the download page. Vendoring into
# mrbgems/mruby-sqlite3/src/ is a manual copy step afterwards (see that
# gem's README); rake never touches the network.
sqlite: $(SQLITE_ZIP)

# Note: verified with openssl, not shasum — BSD shasum has no SHA-3.
$(SQLITE_ZIP):
	mkdir -p tmp/sqlite
	curl -fSL -o $@ \
		https://www.sqlite.org/$(SQLITE_YEAR)/sqlite-amalgamation-$(SQLITE_VERSION).zip
	test "$$(openssl dgst -sha3-256 $@ | sed 's/^.*= //')" = "$(SQLITE_SHA3_256)"

# Cross-builds the rm2fb display server (swtcon mode) from the rM2-stuff
# checkout, mirroring its CI: toltec toolchain via switch-arm.sh + the
# release-toltec preset's cache variables. Only the three artifacts the
# device install needs are built; they're collected in build/rm2fb/dist/.
# GHOSTTY_VT_PREFIX points at an empty stub tree on purpose: it makes
# vendor/libghostty register an imported lib and return, instead of requiring
# zig + fetching ghostty — only the yaft app (which we don't build) links it.
# The dirs must exist because cmake validates interface include paths at
# generate time even for targets that are never built.
rm2fb: image | $(RM2STUFF_DIR)
	docker run --rm --platform $(PLATFORM) \
		-v $(CURDIR):/work \
		-v $(abspath $(RM2STUFF_DIR)):/rm2-stuff \
		-w /rm2-stuff $(IMAGE) bash -c '\
		. /opt/x-tools/switch-arm.sh && \
		mkdir -p /tmp/ghostty-stub/include /tmp/ghostty-stub/lib && \
		touch /tmp/ghostty-stub/lib/libghostty-vt.a && \
		cmake -S /rm2-stuff -B /work/build/rm2fb -G Ninja \
			-DCMAKE_TOOLCHAIN_FILE=/usr/share/cmake/$$CHOST.cmake \
			-DCMAKE_BUILD_TYPE=MinSizeRel \
			-DCMAKE_C_FLAGS=-Wno-psabi -DCMAKE_CXX_FLAGS=-Wno-psabi \
			-DGHOSTTY_VT_PREFIX=/tmp/ghostty-stub && \
		cmake --build /work/build/rm2fb \
			--target rm2fb_server_swtcon rm2fb_client_swtcon rm2fbctl && \
		mkdir -p /work/build/rm2fb/dist && \
		cp -L /work/build/rm2fb/libs/rm2fb/rm2fb_server_swtcon \
			/work/build/rm2fb/libs/rm2fb/rm2fbctl \
			/work/build/rm2fb/libs/rm2fb/librm2fb_client_swtcon.so \
			/work/build/rm2fb/dist/'

shell: image | $(MRUBY_DIR)
	docker run --rm -it --platform $(PLATFORM) \
		-v $(CURDIR):/work \
		-v $(abspath $(MRUBY_DIR)):/mruby \
		-w /mruby $(IMAGE) bash

clean:
	rm -rf build build_config.rb.lock
