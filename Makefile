NEXAWRT_FLAVOR ?= official

ifeq ($(NEXAWRT_FLAVOR),nss)
DEFAULT_WORK_DIR := .work/openwrt-nss
else
DEFAULT_WORK_DIR := .work/openwrt
endif
WORK_DIR ?= $(DEFAULT_WORK_DIR)

.PHONY: prepare validate build release clean

prepare:
	NEXAWRT_FLAVOR=$(NEXAWRT_FLAVOR) WORK_DIR=$(WORK_DIR) ./scripts/prepare.sh

validate:
	NEXAWRT_FLAVOR=$(NEXAWRT_FLAVOR) ./scripts/validate.sh --source $(WORK_DIR)

build:
	NEXAWRT_FLAVOR=$(NEXAWRT_FLAVOR) WORK_DIR=$(WORK_DIR) ./scripts/build.sh

release:
	NEXAWRT_FLAVOR=$(NEXAWRT_FLAVOR) WORK_DIR=$(WORK_DIR) ./scripts/release.sh

clean:
	rm -rf .work build.log build-nss.log dist dist-nss
	mkdir -p dist
	touch dist/.gitkeep
