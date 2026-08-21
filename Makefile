# Makefile — every target is a thin Docker wrapper; nothing runs on the Mac.
IMAGE        := redoku-build
MRUBY_DIR    ?= ../mruby
RM2STUFF_DIR ?= ../rM2-stuff
PLATFORM     := linux/amd64

DOCKER_RUN := docker run --rm --platform $(PLATFORM) \
	-v $(CURDIR):/work \
	-v $(abspath $(MRUBY_DIR)):/mruby \
	-w /mruby $(IMAGE)

RAKE := rake MRUBY_CONFIG=/work/build_config.rb MRUBY_BUILD_DIR=/work/build

.PHONY: image build test rm2fb shell clean

image:
	docker build --platform $(PLATFORM) -t $(IMAGE) docker

build: image
	$(DOCKER_RUN) $(RAKE)

test: image
	$(DOCKER_RUN) $(RAKE) test

# Cross-builds the rm2fb display server (swtcon mode) from the rM2-stuff
# checkout, mirroring its CI: toltec toolchain via switch-arm.sh + the
# release-toltec preset's cache variables. Only the three artifacts the
# device install needs are built; they're collected in build/rm2fb/dist/.
# GHOSTTY_VT_PREFIX points at an empty stub tree on purpose: it makes
# vendor/libghostty register an imported lib and return, instead of requiring
# zig + fetching ghostty — only the yaft app (which we don't build) links it.
# The dirs must exist because cmake validates interface include paths at
# generate time even for targets that are never built.
rm2fb: image
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

shell: image
	docker run --rm -it --platform $(PLATFORM) \
		-v $(CURDIR):/work \
		-v $(abspath $(MRUBY_DIR)):/mruby \
		-w /mruby $(IMAGE) bash

clean:
	rm -rf build build_config.rb.lock
