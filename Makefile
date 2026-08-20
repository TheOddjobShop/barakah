# Barakah — a macOS menu bar prayer companion.
#
# `make` alone does the whole golden path: build, clear stale permission grants,
# install to /Applications, and relaunch. Everything else is a narrower slice of
# that same sequence.

APP          := Barakah
BUNDLE_ID    := dev.justin06lee.barakah
VERSION      := 0.1.0
BUILD        := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)

BUILD_DIR    := .build
# `swift build --arch` writes to apple/Products/Release; a plain build does not.
BINARY        = $(shell test -f $(BUILD_DIR)/apple/Products/Release/$(APP) \
                  && echo $(BUILD_DIR)/apple/Products/Release/$(APP) \
                  || echo $(BUILD_DIR)/release/$(APP))
DIST         := dist
BUNDLE       := $(DIST)/$(APP).app
CONTENTS     := $(BUNDLE)/Contents
INSTALL_DIR  := /Applications

# Ad-hoc signing by default. Export DEVELOPER_ID to sign for distribution:
#   export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
DEVELOPER_ID ?= -
ENTITLEMENTS := Resources/Barakah.entitlements

# Hardened runtime is required for notarization, and harmless without it.
CODESIGN_FLAGS := --force --options runtime --timestamp=none \
                  --entitlements $(ENTITLEMENTS)
ifeq ($(DEVELOPER_ID),-)
CODESIGN_FLAGS := --force --entitlements $(ENTITLEMENTS)
endif

.DEFAULT_GOAL := all
.PHONY: all build build-universal bundle icon install update run stop test clean \
        reset-permissions adhan sign notarize dmg check cask

## The whole golden path.
all: stop reset-permissions bundle install run
	@echo "==> $(APP) $(VERSION) is installed and running."
	@echo "    Look for the crescent in your menu bar."

## Compile the release binary for this machine's architecture.
build:
	@echo "==> Building $(APP) $(VERSION) (build $(BUILD))"
	@swift build -c release --disable-sandbox

## Compile a universal binary, for anything that leaves this machine.
build-universal:
	@echo "==> Building $(APP) $(VERSION) universal (arm64 + x86_64)"
	@swift build -c release --disable-sandbox --arch arm64 --arch x86_64

## Regenerate the .icns from the source SVG.
icon: $(BUILD_DIR)/$(APP).icns
$(BUILD_DIR)/$(APP).icns: assets/icon.svg
	@command -v rsvg-convert >/dev/null || { \
		echo "!! rsvg-convert not found. Install it with: brew install librsvg"; exit 1; }
	@echo "==> Rendering app icon"
	@rm -rf $(BUILD_DIR)/icon.iconset && mkdir -p $(BUILD_DIR)/icon.iconset
	@for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 \
	             256:128x128@2x 256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do \
		size=$${spec%%:*}; name=$${spec##*:}; \
		rsvg-convert -w $$size -h $$size assets/icon.svg \
			-o $(BUILD_DIR)/icon.iconset/icon_$$name.png; \
	done
	@iconutil -c icns $(BUILD_DIR)/icon.iconset -o $@

## Assemble the .app bundle.
bundle: build icon
	@echo "==> Assembling $(BUNDLE)"
	@rm -rf $(BUNDLE)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources/Athan
	@cp $(BINARY) $(CONTENTS)/MacOS/$(APP)
	@cp $(BUILD_DIR)/$(APP).icns $(CONTENTS)/Resources/$(APP).icns
	@sed -e 's|__VERSION__|$(VERSION)|' -e 's|__BUILD__|$(BUILD)|' \
		Resources/Info.plist > $(CONTENTS)/Info.plist
	@printf 'APPL????' > $(CONTENTS)/PkgInfo
	@# Any athan recordings sitting in Resources/Athan get bundled. The repo
	@# ships none — see assets/NOTICE.md — so this is normally empty.
	@if [ -d Resources/Athan ]; then cp -R Resources/Athan/. $(CONTENTS)/Resources/Athan/ 2>/dev/null || true; fi
	@$(MAKE) --no-print-directory sign

## Code-sign the bundle.
sign:
	@echo "==> Signing with identity: $(DEVELOPER_ID)"
	@codesign $(CODESIGN_FLAGS) --sign "$(DEVELOPER_ID)" $(BUNDLE)
	@codesign --verify --deep --strict $(BUNDLE) && echo "    signature valid"

## Clear stale privacy grants.
##
## macOS ties Automation and Location grants to the binary's signature. Every
## rebuild of an ad-hoc-signed app invalidates them while System Settings keeps
## showing the old entry as enabled — and the new binary often will not even
## re-prompt until that stale entry is gone. So it is cleared here, every time,
## rather than documented as something for you to do by hand.
reset-permissions:
	@echo "==> Clearing stale privacy grants for $(BUNDLE_ID)"
	@-osascript -e 'quit app "System Settings"' 2>/dev/null || true
	@-tccutil reset AppleEvents $(BUNDLE_ID) >/dev/null 2>&1 || true
	@-tccutil reset Location $(BUNDLE_ID) >/dev/null 2>&1 || true
	@-rm -rf $(INSTALL_DIR)/$(APP).app

## Install into /Applications.
install: bundle
	@echo "==> Installing to $(INSTALL_DIR)"
	@rm -rf $(INSTALL_DIR)/$(APP).app
	@cp -R $(BUNDLE) $(INSTALL_DIR)/
	@# Let Launch Services notice the new bundle straight away.
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
		-f $(INSTALL_DIR)/$(APP).app 2>/dev/null || true

## Launch the installed app.
run:
	@echo "==> Launching $(APP)"
	@open $(INSTALL_DIR)/$(APP).app

## Quit any running copy.
stop:
	@-osascript -e 'quit app "$(APP)"' 2>/dev/null || true
	@-pkill -x $(APP) 2>/dev/null || true
	@sleep 1

## Full refresh of a running install: stop, wipe, rebuild, reinstall, relaunch.
update: stop reset-permissions bundle install run
	@echo "==> $(APP) updated to $(VERSION) (build $(BUILD))."

## Run the test suite.
test:
	@swift test

## Build and typecheck without installing — what CI runs.
check:
	@swift build -c release --disable-sandbox
	@swift test

## Fetch a freely-licensed adhan recording.
adhan:
	@./scripts/fetch-adhan.sh

## Package a distributable disk image.
dmg: build-universal
	@$(MAKE) --no-print-directory bundle
	@echo "==> Building $(DIST)/$(APP)_$(VERSION)_universal.dmg"
	@rm -f $(DIST)/$(APP)_$(VERSION)_universal.dmg
	@mkdir -p $(DIST)/dmg && rm -rf $(DIST)/dmg/*
	@cp -R $(BUNDLE) $(DIST)/dmg/
	@ln -s /Applications $(DIST)/dmg/Applications
	@hdiutil create -volname "$(APP) $(VERSION)" -srcfolder $(DIST)/dmg \
		-ov -format ULFO $(DIST)/$(APP)_$(VERSION)_universal.dmg >/dev/null
	@rm -rf $(DIST)/dmg
	@lipo -archs $(CONTENTS)/MacOS/$(APP) | sed 's/^/    architectures: /'
	@echo "    $(DIST)/$(APP)_$(VERSION)_universal.dmg"

## Notarize the disk image. Requires a Developer ID and a stored credential
## profile: xcrun notarytool store-credentials barakah --apple-id … --team-id …
notarize: dmg
	@if [ "$(DEVELOPER_ID)" = "-" ]; then \
		echo "!! Set DEVELOPER_ID to a Developer ID Application identity first."; exit 1; fi
	@echo "==> Submitting for notarization"
	@xcrun notarytool submit $(DIST)/$(APP)_$(VERSION)_universal.dmg \
		--keychain-profile barakah --wait
	@xcrun stapler staple $(DIST)/$(APP)_$(VERSION)_universal.dmg
	@echo "    stapled: $(DIST)/$(APP)_$(VERSION)_universal.dmg"

clean:
	@rm -rf $(BUILD_DIR) $(DIST)
	@echo "==> Cleaned"

## Print the Homebrew cask for the built disk image, with its real checksum.
## Paste the output into justin06lee/homebrew-tap/Casks/barakah.rb after the
## GitHub release exists.
cask:
	@test -f $(DIST)/$(APP)_$(VERSION)_universal.dmg || { \
		echo "!! No disk image yet. Run: make dmg"; exit 1; }
	@sed -e 's|__VERSION__|$(VERSION)|' \
	     -e "s|__SHA256__|$$(shasum -a 256 $(DIST)/$(APP)_$(VERSION)_universal.dmg | cut -d' ' -f1)|" \
	     packaging/barakah.rb
