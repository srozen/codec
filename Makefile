# Convenience targets. Builds use two jobs to keep memory use reasonable.
JOBS ?= 2

.PHONY: build test app run release screenshots clean

build:
	swift build -j $(JOBS)

test:
	swift build -j $(JOBS) --build-tests
	swift test -j $(JOBS) --skip-build

app:
	scripts/build-app.sh release

run: app
	open build/Codec.app

# A signed, notarized disk image: make release VERSION=1.2.0.
release:
	JOBS=$(JOBS) scripts/release.sh $(VERSION)

# Retakes docs/images; windows open on screen while it runs.
screenshots:
	JOBS=$(JOBS) scripts/screenshots.sh

clean:
	rm -rf .build build
