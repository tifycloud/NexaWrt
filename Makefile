NEXAWRT_FLAVOR ?= official

ifeq ($(NEXAWRT_FLAVOR),nss)
DEFAULT_WORK_DIR := .work/openwrt-nss
STAGE_SCRIPT := ./scripts/stage-nss-artifact.sh
else
DEFAULT_WORK_DIR := .work/openwrt
STAGE_SCRIPT := ./scripts/release.sh
endif
WORK_DIR ?= $(DEFAULT_WORK_DIR)

.PHONY: prepare validate build release clean

prepare:
	env NEXAWRT_FLAVOR="$(NEXAWRT_FLAVOR)" WORK_DIR="$(WORK_DIR)" ./scripts/prepare.sh

validate:
	env NEXAWRT_FLAVOR="$(NEXAWRT_FLAVOR)" ./scripts/validate.sh --source "$(WORK_DIR)"

build:
	env NEXAWRT_FLAVOR="$(NEXAWRT_FLAVOR)" WORK_DIR="$(WORK_DIR)" ./scripts/build.sh

release:
	env NEXAWRT_FLAVOR="$(NEXAWRT_FLAVOR)" WORK_DIR="$(WORK_DIR)" $(STAGE_SCRIPT)

clean:
	rm -rf .work release-staging verified-dist build.log build-nss.log dist dist-nss
	mkdir -p dist
	touch dist/.gitkeep
