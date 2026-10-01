DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/Debug/Frost.app

.PHONY: gen build release install test-core run clean dist sparkle-public-key dmg-background vm-up vm-deploy vm-run vm-shot vm-logs vm-down

gen:
	xcodegen generate --quiet

build: gen
	xcodebuild -project Frost.xcodeproj -scheme Frost -configuration Debug \
	  -destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED) -quiet build

RELEASE_APP := $(DERIVED)/Build/Products/Release/Frost.app

release: gen
	xcodebuild -project Frost.xcodeproj -scheme Frost -configuration Release \
	  -destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED) -quiet build

# Install to /Applications and launch (runs Frost on this machine)
install: release
	-osascript -e 'quit app "Frost"'
	-pkill -x Frost
	rm -rf /Applications/Frost.app
	ditto $(RELEASE_APP) /Applications/Frost.app
	open /Applications/Frost.app

test-core:
	cd Packages/FrostCore && swift test

run: build
	-pkill -x Frost
	open $(APP)

clean:
	rm -rf build Frost.xcodeproj

# ---- Releasing (see docs/releasing.md) ----
# make dist VERSION=0.2.0 [RELEASE_FLAGS=--publish|--allow-dirty]: package (by default only builds the artifacts and prints the publish command)
dist:
	@test -n "$(VERSION)" || { echo "usage: make dist VERSION=x.y.z [RELEASE_FLAGS=--publish]"; exit 1; }
	scripts/release/release.sh $(VERSION) $(RELEASE_FLAGS)

# Print the public key of the Sparkle EdDSA key in the login keychain (must match SUPublicEDKey in project.yml)
sparkle-public-key:
	$(DERIVED)/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account dev.frost.Frost -p

# Regenerate the DMG background images (drawn offscreen)
dmg-background:
	swift scripts/release/dmg/make-background.swift scripts/release/dmg

# ---- GUI testing in the isolated tart VM (see docs/testing-vm.md) ----
SHOT ?= build/vm-shots/shot-$(shell date +%Y%m%d-%H%M%S).png

vm-up:
	scripts/vm/vm-up.sh

vm-deploy:
	scripts/vm/vm-deploy.sh

vm-run:
	scripts/vm/vm-run.sh $(if $(FROST_ENV),$(foreach e,$(FROST_ENV),-e $(e)))

vm-shot:
	scripts/vm/vm-screenshot.sh $(SHOT)

vm-logs:
	scripts/vm/vm-logs.sh

vm-down:
	scripts/vm/vm-down.sh
