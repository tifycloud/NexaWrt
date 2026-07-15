.PHONY: prepare validate build release clean

prepare:
	./scripts/prepare.sh

validate:
	./scripts/validate.sh --source .work/openwrt

build:
	./scripts/build.sh

release:
	./scripts/release.sh

clean:
	rm -rf .work build.log dist
	mkdir -p dist
	touch dist/.gitkeep
