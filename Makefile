APP = Claude Island.app
BINARY = .build/release/ClaudeIsland
# Single source of truth for the version: AppInfo.swift. Stamped into the
# bundle's Info.plist below so Finder and the About page always agree.
VERSION = $(shell sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' Sources/ClaudeIsland/Core/AppInfo.swift)
# Signing: ad-hoc by default, so a fresh clone builds with zero prompts and
# zero setup. If the deliberately-created "Claude Island Signing" identity
# exists (docs/SIGNING.md), use it so keychain approvals survive rebuilds.
# Never auto-grab other identities — surprising the keychain scares people.
# Override with any identity: make SIGN_ID="Apple Development: You" bundle
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q '"Claude Island Signing"' && echo "Claude Island Signing" || echo "-")

.PHONY: all build bundle run test install clean

all: bundle

build:
	swift build -c release

bundle: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp Support/Info.plist "$(APP)/Contents/Info.plist"
	/usr/bin/plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(APP)/Contents/Info.plist"
	cp "$(BINARY)" "$(APP)/Contents/MacOS/ClaudeIsland"
	mkdir -p "$(APP)/Contents/Resources"
	cp Support/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	codesign --force -s "$(SIGN_ID)" "$(APP)"

run: bundle
	open "$(APP)"

# Put the app where LaunchServices can find it: Spotlight, Login Items, and
# `open -a "Claude Island"` from any shell all work after this. Quits a
# running copy first — `open` never replaces a live instance.
install: bundle
	@pkill -x ClaudeIsland 2>/dev/null || true
	rm -rf "/Applications/$(APP)"
	cp -R "$(APP)" /Applications/
	open "/Applications/$(APP)"

test:
	swift test

clean:
	rm -rf .build "$(APP)"
