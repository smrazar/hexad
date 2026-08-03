#!/bin/bash
# Build hexad and install it into /Applications.
#
# `swift build` alone produces a binary in .build that has no icon, no Info.plist and no place
# in the Finder — which is exactly what "there is no app in my Applications folder" looks like.
# This is the step that makes the app real.
#
#   ./Scripts/install.sh            build and install, keeping existing settings
#   ./Scripts/install.sh --fresh    wipe every trace first, as a new user would meet it
#
# --fresh is the handover mode, and it is the one to use before asking anyone to look at the app.
# Leftover state hides bugs: onboarding never reappears, a default that changed in the source is
# masked by the old stored value, and a first-run path stays untested for the life of the app.

set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/hexad.app"
TARGET="/Applications/hexad.app"
BUNDLE_ID="com.smrazar.hexad"

FRESH=0
CONFIG="release"
for argument in "$@"; do
    case "$argument" in
        --fresh) FRESH=1 ;;
        debug|release) CONFIG="$argument" ;;
        *) echo "install: unknown option $argument" >&2; exit 2 ;;
    esac
done

./Scripts/build.sh "$CONFIG"

# A running copy holds its bundle open and would be replaced underneath itself.
if pgrep -x hexad > /dev/null; then
    echo "==> quitting the running hexad"
    osascript -e 'quit app "hexad"' 2>/dev/null || pkill -x hexad || true
    sleep 1
fi

# Wiped after the quit above, so the app cannot write its state back out on the way down — and
# before the copy, so the new build's first launch is genuinely a first launch.
#
# Every path here is hexad's own. The list is deliberately exhaustive rather than the obvious two:
# each entry below has, at some point, survived a "fresh" install and hidden a bug behind state
# the next launch should never have seen.
if [ "$FRESH" = "1" ]; then
    echo "==> fresh: removing every trace of the previous install"

    remove() {
        [ -e "$1" ] || return 0
        rm -rf "$1" && echo "    removed  ${1/#$HOME/~}"
    }

    defaults delete "$BUNDLE_ID" 2>/dev/null \
        && echo "    removed  preferences domain $BUNDLE_ID" \
        || echo "    (none)   preferences domain $BUNDLE_ID"

    # The domain can also exist as files that `defaults delete` leaves behind, and ByHost holds a
    # per-machine copy that survives the main one.
    remove "$HOME/Library/Preferences/$BUNDLE_ID.plist"
    for byhost in "$HOME/Library/Preferences/ByHost/$BUNDLE_ID".*.plist; do remove "$byhost"; done

    # cfprefsd caches the domain in memory and will serve the old values straight back to the new
    # process, which makes a wiped preference look like a preference that was never wiped.
    killall -u "$USER" cfprefsd 2>/dev/null && echo "    restarted cfprefsd" || true

    remove "$HOME/Library/Application Support/hexad"
    remove "$HOME/Library/Logs/hexad.log"
    remove "$HOME/Library/Caches/$BUNDLE_ID"
    remove "$HOME/Library/HTTPStorages/$BUNDLE_ID"
    remove "$HOME/Library/WebKit/$BUNDLE_ID"
    remove "$HOME/Library/Cookies/$BUNDLE_ID.binarycookies"
    # macOS Resume. NSQuitAlwaysKeepsWindows is false so this should never appear — which is
    # exactly why it is worth deleting rather than trusting.
    remove "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
    remove "$HOME/Library/Application Scripts/$BUNDLE_ID"
    remove "$HOME/Library/Containers/$BUNDLE_ID"

    # hexad restores the system ⌘Tab when it quits, but a crash during the last session can leave
    # the flag orphaned — and a fresh install should not inherit a machine with no ⌘Tab.
    "$APP/Contents/MacOS/hexad" --system-switcher --restore 2>&1 | sed 's/^/    /' || true
fi

echo "==> installing to $TARGET"
rm -rf "$TARGET"
cp -R "$APP" "$TARGET"

# macOS caches icons in two places and `touch` only defeats one of them. Launch Services keeps its
# own record keyed on the bundle, and the Dock keeps a rendered copy — so a genuinely new icon can
# keep showing as the old one, or as a blank sheet of paper, long after the bundle changed. That
# looks exactly like an icon that failed to build, which is a very expensive thing to debug.
touch "$TARGET"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$TARGET" 2>/dev/null && echo "    re-registered with Launch Services" || true
fi
# The Dock re-reads the icon when it restarts, and restarting it is instant and non-destructive.
killall Dock 2>/dev/null && echo "    restarted Dock (icon cache)" || true

# Accessibility has to be re-granted after every install, and this is why:
#
# hexad is ad-hoc signed, because there is no signing identity on this machine. An ad-hoc
# signature changes every time the binary changes, and TCC records the grant against that
# signature. So a rebuilt hexad is, to macOS, a different app wearing the same name — the
# toggle still reads ON in System Settings while `AXIsProcessTrusted()` returns false.
#
# That combination is worse than a plain denial: it looks granted and behaves denied. Clearing
# the stale record makes the app ask again instead of sitting there silently not working.
#
# That reasoning holds **only while the app is ad-hoc signed**. `Scripts/make-identity.sh` creates
# a stable self-signed identity, and once it exists the signature no longer changes between
# builds — so the grant survives, and resetting it every install would be the script destroying
# the exact thing the identity was created to preserve.
#
# So the reset is conditional on how the bundle that is being installed is actually signed. Read
# from the bundle rather than assumed, because the two scripts can disagree: the identity might
# have been created after this app was last built.
if codesign -dv "$TARGET" 2>&1 | grep -q "Signature=adhoc"; then
    echo "==> clearing the stale permission grants (ad-hoc signature changed)"
    tccutil reset Accessibility "$BUNDLE_ID" 2>&1 | sed 's/^/    /' || true
    # Screen Recording has exactly the same problem and was not being reset, which is why window
    # previews stayed blank after the permission had visibly been granted: the row in System
    # Settings was left by an earlier signature, so it read ON while the capture returned nothing.
    tccutil reset ScreenCapture "$BUNDLE_ID" 2>&1 | sed 's/^/    /' || true
    NEEDS_REGRANT=yes
else
    AUTHORITY=$(codesign -d --verbose=4 "$TARGET" 2>&1 | grep '^Authority=' | head -1 \
        | cut -d= -f2)
    echo "==> keeping the permission grants (stable identity: ${AUTHORITY:-unknown})"
    echo "    The signature no longer changes between builds, so the grants survive."
    NEEDS_REGRANT=no
fi

echo "==> launching"
open "$TARGET"
echo "==> installed: $TARGET"
echo
if [ "$NEEDS_REGRANT" = yes ]; then
    echo "    Accessibility must be granted again — the signature changed."
    echo "    hexad menu bar icon ▸ Settings… ▸ Grant…"
    echo "    Run ./Scripts/make-identity.sh once to stop this happening every build."
else
    echo "    Permissions were left alone. If this is the first signed build, grant"
    echo "    Accessibility once more — the identity changed from ad-hoc — and it should"
    echo "    then survive every rebuild from here."
fi
echo "    Then check:  tail -1 ~/Library/Logs/hexad.log"
