# Makefile — every target is a thin Docker wrapper; nothing runs on the Mac.
IMAGE     := redoku-build
MRUBY_DIR ?= ../mruby
PLATFORM  := linux/amd64

DOCKER_RUN := docker run --rm --platform $(PLATFORM) \
	-v $(CURDIR):/work \
	-v $(abspath $(MRUBY_DIR)):/mruby \
	-w /mruby $(IMAGE)

RAKE := rake MRUBY_CONFIG=/work/build_config.rb MRUBY_BUILD_DIR=/work/build

.PHONY: image build test shell clean

image:
	docker build --platform $(PLATFORM) -t $(IMAGE) docker

build: image
	$(DOCKER_RUN) $(RAKE)

test: image
	$(DOCKER_RUN) $(RAKE) test

shell: image
	docker run --rm -it --platform $(PLATFORM) \
		-v $(CURDIR):/work \
		-v $(abspath $(MRUBY_DIR)):/mruby \
		-w /mruby $(IMAGE) bash

clean:
	rm -rf build
