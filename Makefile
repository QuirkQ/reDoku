# Makefile — every target is a thin Docker wrapper; nothing runs on the Mac.
IMAGE        := redoku-build
# Sibling checkouts are used when they exist; otherwise the pinned
# versions below are cloned into tmp/ (gitignored) on first use.
MRUBY_DIR    ?= $(firstword $(wildcard ../mruby) tmp/mruby)
RM2STUFF_DIR ?= $(firstword $(wildcard ../rM2-stuff) tmp/rM2-stuff)
MRUBY_REF    := 4.0.0
RM2STUFF_REF := 451577081b9eaa3d582e50bbca8c4adfd4911b53
PLATFORM     := linux/amd64

DOCKER_RUN := docker run --rm --platform $(PLATFORM) \
	-v $(CURDIR):/work \
	-v $(abspath $(MRUBY_DIR)):/mruby \
	-w /mruby $(IMAGE)

RAKE := rake MRUBY_CONFIG=/work/build_config.rb MRUBY_BUILD_DIR=/work/build

.PHONY: image build test rm2fb shell clean

image:
	docker build --platform $(PLATFORM) -t $(IMAGE) docker

build: image | $(MRUBY_DIR)
	$(DOCKER_RUN) $(RAKE)

test: image | $(MRUBY_DIR)
	$(DOCKER_RUN) $(RAKE) test

tmp/mruby:
	git clone --depth 1 --branch $(MRUBY_REF) https://github.com/mruby/mruby.git $@

tmp/rM2-stuff:
	git clone https://github.com/QuirkQ/rM2-stuff.git $@
	git -C $@ checkout $(RM2STUFF_REF)

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
