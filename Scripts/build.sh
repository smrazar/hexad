#!/bin/bash
# Build hexad.app from the SwiftPM package.
#
# There is no Xcode project here, so the bundle is assembled by hand. A bare executable does not
# get a menu bar item — NSStatusItem needs a real bundle with an Info.plist — which is why this
# script exists rather than `swift build` being enough.
#
# Fails on a self-check failure, because a check the build ignores is a check that stops being true.

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="hexad"
BUNDLE_ID="com.smrazar.hexad"
VERSION="0.6.2"
CONFIG="${1:-release}"

echo "==> swift build -c $CONFIG"
# A release build embeds the absolute path of every source file and object file — in the DWARF
# debug info, and in the linker's debug map (the N_OSO entries). On this machine that means
# "/Users/m/..." shipped inside the binary of every published release, ~100 occurrences each.
#
# `strings` does not show them: Apple's strings only dumps __TEXT on a Mach-O and never looks at
# __DWARF, so a scan of the binary comes back clean while the paths are sitting right there.
# Checked with `python3 ~/Developer/scan-personal-data.py <App>.app` instead.
#
#   -file-prefix-map  rewrites source paths to ./Sources/...
#   -oso_prefix       strips the build directory from the linker's debug map
#
# Both are needed; either alone leaves half the paths behind.
swift build -c "$CONFIG" -Xswiftc -file-prefix-map -Xswiftc "$PWD=." \
    -Xcc -ffile-prefix-map="$PWD=." -Xlinker -oso_prefix -Xlinker "$PWD/"

BIN=".build/$CONFIG/$APP_NAME"
APP="build/$APP_NAME.app"

echo "==> self-check (in the binary that ships)"
"$BIN" --self-check

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# The icon. Without it the app is a white sheet of paper in the Applications folder, which is
# how a real app and a build artefact tell themselves apart at a glance.
#
# The app icon is authored artwork: Assets/icon.svg, with the editable original beside it. It is
# deliberately a different file from the menu-bar glyph — the two used to share one source, so a
# change to either moved both. Rendered every build, so editing the artwork is all it takes.
#
# iconutil is not used: it rejects every iconset on this machine, including ones it produced
# itself. make-icon.swift rasterises each size from the SVG and writes the .icns chunks directly.
ICON_ART="Assets/icon.svg"
if [ -f "$ICON_ART" ]; then
    echo "==> icon"
    swift Tools/make-icon.swift "$ICON_ART" "$APP/Contents/Resources/AppIcon.icns" | sed 's/^/    /'
fi

# The menu bar glyph, from the same family as the app icon. Also regenerated every build, so
# editing Assets/hexad-glyph.svg is all it takes to change the mark in the menu bar.
if [ -f "Assets/hexad-glyph.svg" ]; then
    echo "==> menu bar glyph"
    swift Scripts/make-glyph.swift
    cp build/MenuGlyph.pdf "$APP/Contents/Resources/MenuGlyph.pdf"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>

    <!-- Menu bar utility: no Dock icon, no app menu. -->
    <key>LSUIElement</key><true/>

    <!-- macOS Resume is a second restorer working from worse information. Off for the whole
         app, because per-window isRestorable does not cover AppKit's own panels.
         See ~/Developer/macos-app-notes.md -->
    <key>NSQuitAlwaysKeepsWindows</key><false/>

    <!-- Shown in the Screen Recording prompt. Previews ship **on** as of 0.6.1, so this is
         reached during onboarding rather than never — the step asks, explains that it is
         optional, and offers "do it later". See the note on Preferences.showsThumbnails for
         why that reverses PLAN.md §2. -->
    <key>NSScreenCaptureUsageDescription</key>
    <string>hexad shows a preview of each window in the switcher.</string>
</dict>
</plist>
PLIST

# Sign with the stable local identity when there is one, ad-hoc when there is not.
#
# Ad-hoc signing changes the app's identity on every single build, and TCC keys its grants on
# that identity — so a rebuild silently drops Accessibility and Screen Recording while their
# switches in System Settings stay on and the APIs return false. That is the root cause behind
# both permission bugs in docs/BUGS.md.
#
# Run ./Scripts/make-identity.sh once to create the identity. It is not run from here on purpose:
# it writes to the login keychain, which a build has no business doing unasked.
SIGN_IDENTITY="hexad Local Signing"
# **Sign by SHA-1 hash, not by name.** Trusting the certificate puts a copy in the System keychain
# while the private key stays in the login keychain, so the *name* matches twice and codesign
# refuses outright:
#
#     hexad Local Signing: ambiguous (matches "hexad Local Signing" in
#     /Library/Keychains/System.keychain and ... login.keychain-db)
#
# Both entries are the same certificate with the same hash, so the hash names it unambiguously and
# keeps working however many keychains hold a copy.
SIGN_HASH=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "$SIGN_IDENTITY" | head -1 | awk '{print $2}')
if [ -n "$SIGN_HASH" ]; then
    echo "==> signing with '$SIGN_IDENTITY' ($SIGN_HASH)"
    # Never --deep: it re-signs inner bundles without their entitlements.
    codesign --force --options runtime --sign "$SIGN_HASH" "$APP" 2>&1 | sed 's/^/    /'
else
    echo "==> ad-hoc signing"
    echo "    Permissions will be dropped on every rebuild. ./Scripts/make-identity.sh fixes it."
    codesign --force --sign - "$APP" 2>&1 | sed 's/^/    /'
fi

echo "==> done: $APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature' | sed 's/^/    /' || true
