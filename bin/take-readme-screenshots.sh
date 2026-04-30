#!/usr/bin/env bash
# bin/take-readme-screenshots.sh — regenerate docs/screenshots/{ios,macos}-home.png
# from the running app on iOS Simulator + native macOS, fully autonomously.
#
# Usage:
#   bin/take-readme-screenshots.sh                          # auto-detect scheme + bundle from app/*.xcodeproj
#   bin/take-readme-screenshots.sh --device "iPhone 16 Pro" # override iOS Simulator device
#   bin/take-readme-screenshots.sh --os 18.6                # pin iOS Simulator OS version
#
# Why this exists:
#   After `bin/rename.sh` substitutes the app's identity strings, the shipped
#   README screenshots still show the original "HelloApp" stub — which misleads
#   anyone viewing the forker's repo. This script regenerates docs/screenshots/
#   from whatever the current app is (pre-rename HelloApp, or post-rename
#   YourApp). Also useful when ContentView changes upstream.
#
# Capture chain (zero keystrokes; no Accessibility permission needed):
#
#   iOS:    xcrun simctl io booted screenshot — produces 2x retina PNG.
#   macOS:  Quartz CGWindowListCopyWindowInfo (Python) → kCGWindowNumber → screencapture -l <wid> -o
#           This bypasses Accessibility/System Events permission. The `-o` flag
#           drops the window's drop-shadow padding for tighter framing.
#
# The Quartz approach is the autonomy-friendly macOS-window-query pattern:
#   - osascript "tell application \"System Events\"" requires Accessibility
#     permission (interactive grant prompt; fails in headless bash sessions)
#   - Python's Quartz.CGWindowListCopyWindowInfo enumerates windows + their
#     metadata WITHOUT requiring Accessibility (it's read-only window metadata)
#   - screencapture -l <wid> accepts the window-id directly; no permission
#     prompts beyond Screen Recording (one-time grant for the terminal)
#
# Tooling required (all macOS-bundled or already-installed for this project):
#   xcodebuild, xcrun simctl, screencapture, python3, open, pkill, xcodegen
#
# Constraints (parity with bin/rename.sh):
#   - bash 3.2+ (macOS system bash); no bash 4+ features
#   - BSD-portable; no GNU-specific flags
#   - No new external dependencies

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ✓ %s\n' "$*"; }
fail() { printf '    ✗ %s\n' "$*" >&2; exit 1; }

# ── Defaults + CLI override ────────────────────────────────────────────
DEVICE="iPhone 17 Pro"
IOS_OS=""    # empty = default OS (latest installed); else pinned via -destination

while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --os)     IOS_OS="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# *//; s/^#$//'
      exit 0
      ;;
    *) fail "unknown arg: $1 (see --help)" ;;
  esac
done

# ── Pre-flight ────────────────────────────────────────────────────────
step "Pre-flight"
command -v xcodebuild  >/dev/null || fail "xcodebuild not on PATH"
command -v xcrun       >/dev/null || fail "xcrun not on PATH"
command -v xcodegen    >/dev/null || fail "xcodegen not on PATH — install via 'brew install xcodegen'"
command -v python3     >/dev/null || fail "python3 not on PATH (macOS ships /usr/bin/python3)"
command -v screencapture >/dev/null || fail "screencapture not on PATH (macOS-bundled)"
ok "tools present"

# ── Project + scheme + bundle-id auto-detection ───────────────────────
PROJECT=""
for p in app/*.xcodeproj; do
  [ -d "$p" ] && PROJECT="$p" && break
done
[ -n "$PROJECT" ] || fail "no app/*.xcodeproj found — run 'cd app && xcodegen generate' first"
ok "project: $PROJECT"

step "Regenerate xcodeproj from project.yml"
( cd app && xcodegen generate >/dev/null )
ok "xcodeproj fresh"

step "Auto-detect schemes + bundle ID"
SCHEMES=$(xcodebuild -list -project "$PROJECT" 2>/dev/null \
  | awk '/Schemes:/{flag=1; next} flag && /^[[:space:]]*[A-Za-z]/{print $1}')

SCHEME_IOS=$(echo "$SCHEMES" | grep -E -- '-iOS$' | head -1)
SCHEME_MACOS=$(echo "$SCHEMES" | grep -E -- '-macOS$' | head -1)
[ -n "$SCHEME_IOS"   ] || fail "could not detect *-iOS scheme in $PROJECT"
[ -n "$SCHEME_MACOS" ] || fail "could not detect *-macOS scheme in $PROJECT"
ok "iOS scheme:   $SCHEME_IOS"
ok "macOS scheme: $SCHEME_MACOS"

# APP_NAME prefix (e.g. "HelloApp" from "HelloApp-iOS")
APP_NAME="${SCHEME_IOS%-iOS}"
ok "app name prefix: $APP_NAME"

# Bundle ID from build settings (uses iOS scheme; iOS+macOS share PRODUCT_BUNDLE_IDENTIFIER per project.yml)
BUNDLE_ID=$(xcodebuild -showBuildSettings -project "$PROJECT" -scheme "$SCHEME_IOS" \
  -destination "platform=iOS Simulator,name=$DEVICE" 2>/dev/null \
  | awk -F' = ' '/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER/ {print $2; exit}' | tr -d ' \n')
[ -n "$BUNDLE_ID" ] || fail "could not detect PRODUCT_BUNDLE_IDENTIFIER from $PROJECT"
ok "bundle id: $BUNDLE_ID"

# ── iOS capture ───────────────────────────────────────────────────────
step "Build $SCHEME_IOS for iOS Simulator (device: $DEVICE${IOS_OS:+, OS=$IOS_OS})"
DEST="platform=iOS Simulator,name=$DEVICE"
[ -n "$IOS_OS" ] && DEST="$DEST,OS=$IOS_OS"

if ! xcodebuild build -project "$PROJECT" -scheme "$SCHEME_IOS" \
       -destination "$DEST" -configuration Debug 2>&1 | tail -5 \
       | grep -q "BUILD SUCCEEDED"; then
  fail "iOS build failed (try --device with a different sim or --os to pin)"
fi
ok "iOS build succeeded"

step "Boot Simulator + install + launch + capture"
xcrun simctl boot "$DEVICE" 2>/dev/null || true   # already-booted = no-op error, harmless

APP_IOS=$(find ~/Library/Developer/Xcode/DerivedData -name "$SCHEME_IOS.app" \
            -path '*Debug-iphonesimulator*' 2>/dev/null | head -1)
[ -n "$APP_IOS" ] && [ -d "$APP_IOS" ] || fail "iOS .app not found post-build"
ok "app: $APP_IOS"

xcrun simctl install booted "$APP_IOS"
xcrun simctl launch  booted "$BUNDLE_ID" >/dev/null
sleep 3   # first-frame render

mkdir -p docs/screenshots
xcrun simctl io booted screenshot docs/screenshots/ios-home.png
ok "captured docs/screenshots/ios-home.png ($(wc -c < docs/screenshots/ios-home.png | tr -d ' ') bytes)"

# ── macOS capture ─────────────────────────────────────────────────────
step "Build $SCHEME_MACOS (ad-hoc signing for sandbox bypass)"
# CODE_SIGN_IDENTITY="-" = ad-hoc signing — satisfies macOS sandbox requirement
# without needing a real Apple Development team. Bypasses the
# TEAM_ID_PLACEHOLDER blocker that ships with this template.
if ! xcodebuild build -project "$PROJECT" -scheme "$SCHEME_MACOS" \
       -destination "platform=macOS" -configuration Debug \
       CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" 2>&1 | tail -5 \
       | grep -q "BUILD SUCCEEDED"; then
  fail "macOS build failed"
fi
ok "macOS build succeeded"

step "Launch macOS app + Quartz window-id query + capture"
APP_MACOS=$(find ~/Library/Developer/Xcode/DerivedData \
              -name "$SCHEME_MACOS.app" -path "*Debug/$SCHEME_MACOS.app*" 2>/dev/null | head -1)
[ -n "$APP_MACOS" ] && [ -d "$APP_MACOS" ] || fail "macOS .app not found post-build"
ok "app: $APP_MACOS"

open "$APP_MACOS"
sleep 3   # window-render + AppKit launch settle

# Quartz query — bypasses Accessibility permission
# kCGWindowOwnerName is the truncated process name (e.g. "HelloApp", NOT
# "HelloApp-macOS") because PRODUCT_NAME drops the platform suffix. Match by
# APP_NAME prefix to handle this consistently.
WID=$(python3 - <<EOF
from Quartz import CGWindowListCopyWindowInfo, kCGWindowListOptionOnScreenOnly, kCGNullWindowID
for w in CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID):
    owner = w.get('kCGWindowOwnerName', '')
    name = w.get('kCGWindowName', '') or ''
    if owner.startswith("$APP_NAME") and name.startswith("$APP_NAME"):
        print(w['kCGWindowNumber'])
        break
EOF
)
[ -n "$WID" ] || fail "could not find $APP_NAME window via Quartz (is the app actually running?)"
ok "window id: $WID"

# -l <wid> = capture by window-id; -o = drop drop-shadow padding; -x = silent (no shutter sound)
screencapture -l "$WID" -o -x docs/screenshots/macos-home.png
ok "captured docs/screenshots/macos-home.png ($(wc -c < docs/screenshots/macos-home.png | tr -d ' ') bytes)"

# ── Teardown ──────────────────────────────────────────────────────────
step "Tear down: quit macOS app + shutdown Simulator + quit Simulator.app"
# pkill exit-1 if no match — harmless when app already exited; suppress
pkill -f "$SCHEME_MACOS\$|$SCHEME_MACOS\.app/Contents/MacOS" 2>/dev/null || true
xcrun simctl shutdown "$DEVICE" 2>/dev/null || true
# `tell application "X" to quit` (Apple Events, NOT System Events) does not
# require Accessibility permission. Use this form for app-quit.
osascript -e 'tell application "Simulator" to quit' 2>/dev/null || true
ok "teardown complete"

# ── Done ──────────────────────────────────────────────────────────────
step "Done"
ok "iOS:   docs/screenshots/ios-home.png ($(wc -c < docs/screenshots/ios-home.png | tr -d ' ') bytes)"
ok "macOS: docs/screenshots/macos-home.png ($(wc -c < docs/screenshots/macos-home.png | tr -d ' ') bytes)"
ok ""
ok "Verify both render correctly before committing:"
ok "  open docs/screenshots/ios-home.png"
ok "  open docs/screenshots/macos-home.png"
