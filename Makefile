DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/Debug/Frost.app

.PHONY: gen build release ci-build install test-core lint run clean dist sparkle-public-key dmg-background vm-up vm-deploy vm-run vm-shot vm-logs vm-down

gen:
	xcodegen generate --quiet

build: gen
	xcodebuild -project Frost.xcodeproj -scheme Frost -configuration Debug \
	  -destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED) -quiet build

RELEASE_APP := $(DERIVED)/Build/Products/Release/Frost.app

# Signed with the Developer ID certificate when the keychain has one for the release Team ID (so a locally installed
# build keeps the same signature as published releases and macOS keeps its permission grants); otherwise with the
# self-signed identity from project.yml.
RELEASE_TEAM_ID := $(shell . scripts/release/config.sh >/dev/null 2>&1; echo $$TEAM_ID)
DEVELOPER_ID_SIGN_FLAGS := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q 'Developer ID Application: .*($(RELEASE_TEAM_ID))' && \
  echo 'CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=$(RELEASE_TEAM_ID) CODE_SIGN_ENTITLEMENTS=Frost/Resources/Frost.entitlements')

release: gen
	xcodebuild -project Frost.xcodeproj -scheme Frost -configuration Release \
	  -destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED) -quiet $(DEVELOPER_ID_SIGN_FLAGS) build

# Unsigned Release build for the generic macOS destination (universal), the same command CI runs
# (.github/workflows/ci.yml). Uses its own DerivedData so it doesn't replace the signed build of `make release`.
# Package versions come only from the committed Package.resolved (fails if it is out of date with project.yml).
CI_DERIVED := build/DerivedData-CI
CI_BUILD_FLAGS ?= -quiet

ci-build: gen
	xcodebuild -project Frost.xcodeproj -scheme Frost -configuration Release \
	  -destination 'generic/platform=macOS' -derivedDataPath $(CI_DERIVED) \
	  -onlyUsePackageVersionsFromResolvedFile \
	  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" $(CI_BUILD_FLAGS) build

# Install to /Applications and launch (runs Frost on this machine)
install: release
	-osascript -e 'quit app "Frost"'
	-pkill -x Frost
	rm -rf /Applications/Frost.app
	ditto $(RELEASE_APP) /Applications/Frost.app
	open /Applications/Frost.app

test-core:
	cd Packages/FrostCore && swift test

# The Swift source lint checks of CI's Lint job (.github/workflows/ci.yml): lazy sequence chains (see the script).
lint:
	scripts/lint/lazy-chains.sh

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
