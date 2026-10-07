#!/usr/bin/env bash
# Build FakeItems.app (dev.frost.FakeItems), FakeItemsB.app (dev.frost.FakeItemsB) and FakeItemsDemo.app
# (dev.frost.FakeItemsDemo, shown as "Menu Extras", for README recordings)
# from main.swift into build/FakeItems/, ad-hoc signed. Host build only; the apps
# are meant to run inside the test VM (scripts/vm/vm-fake-items.sh).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/../../build/FakeItems"
mkdir -p "$out"
bin="$out/FakeItems-bin"
swiftc -swift-version 6 -O -target arm64-apple-macos26.0 -o "$bin" "$here/main.swift"
for spec in "FakeItems:dev.frost.FakeItems:FakeItems" "FakeItemsB:dev.frost.FakeItemsB:FakeItemsB" \
  "FakeItemsDemo:dev.frost.FakeItemsDemo:Menu Extras"; do
  IFS=: read -r name id display <<<"$spec"
  app="$out/$name.app"
  rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
  cp "$bin" "$app/Contents/MacOS/$name"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleName</key><string>$display</string>
  <key>CFBundleDisplayName</key><string>$display</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
  codesign --force -s - "$app"
done
rm -f "$bin"
echo "$out"
