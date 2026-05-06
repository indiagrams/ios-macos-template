#!/usr/bin/env bash
# ci/regen-readme-screenshots.sh — regenerate the platform-aware README
# home-screen screenshots:
#
#   docs/screenshots/ios-home.png    — iOS sim, subtitle "iOS template"
#   docs/screenshots/macos-home.png  — macOS app, subtitle "macOS template"
#
# Why this exists:
#   The README's hero shots show the HelloApp stub on iOS + macOS. After
#   bin/rename.sh learned --platforms (PR #72), the stub's subtitle is
#   platform-aware. Capturing the iOS variant with "iOS template" and
#   the macOS variant with "macOS template" makes the README screenshots
#   showcase the platform-aware feature naturally — iOS shot looks
#   iOS-shaped, Mac shot Mac-shaped.
#
# Process per platform:
#   1. Patch app/Shared/ContentView.swift's subtitle to the platform-
#      specific label
#   2. Regenerate Xcode project (xcodegen)
#   3. Build the platform target unsigned
#   4. Launch in simulator (iOS) / launch the .app (macOS)
#   5. Capture screenshot via xcrun simctl io / screencapture -l
#   6. Restore ContentView.swift via git checkout
#
# Idempotent: any failure restores ContentView.swift via the EXIT trap.
# The script does NOT commit changes — caller `git diff --stat` and
# commits the regenerated PNGs separately.
#
# Usage:
#   ci/regen-readme-screenshots.sh                # both platforms
#   ci/regen-readme-screenshots.sh --ios-only     # skip macOS
#   ci/regen-readme-screenshots.sh --macos-only   # skip iOS

set -euo pipefail

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ✓ %s\n' "$*"; }
fail() { printf '    ✗ %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DO_IOS=1
DO_MACOS=1
for arg in "$@"; do
  case "$arg" in
    --ios-only)   DO_MACOS=0 ;;
    --macos-only) DO_IOS=0 ;;
    -h|--help)    sed -n '2,/^set -euo pipefail$/{ /^set -euo pipefail$/!p; }' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            fail "unknown flag '$arg'" ;;
  esac
done

# Pre-flight
test -f app/Shared/ContentView.swift || fail "app/Shared/ContentView.swift missing"
test -f app/project.yml              || fail "app/project.yml missing (this script targets the xcodegen path)"
command -v xcodegen >/dev/null || fail "xcodegen not on PATH"
command -v xcodebuild >/dev/null || fail "xcodebuild not on PATH"
[ "$DO_IOS"   = 1 ] && { command -v xcrun >/dev/null || fail "xcrun not on PATH"; }
[ "$DO_MACOS" = 1 ] && { command -v screencapture >/dev/null || fail "screencapture not on PATH"; }

# Pull current subtitle so we can restore even if the script fails mid-run.
ORIGINAL_SUBTITLE=$(grep -E 'Text\("(iOS template|macOS template|iOS \+ macOS template)"\)' app/Shared/ContentView.swift | head -1 | sed -E 's|.*Text\("([^"]+)"\).*|\1|')
[ -n "$ORIGINAL_SUBTITLE" ] || fail "could not find existing subtitle line in ContentView.swift"
ok "original subtitle: '$ORIGINAL_SUBTITLE'"

restore_content_view() {
  if [ -n "${ORIGINAL_SUBTITLE:-}" ]; then
    git checkout -- app/Shared/ContentView.swift 2>/dev/null || true
  fi
}
trap 'restore_content_view' EXIT INT TERM

patch_subtitle() {
  local new_label="$1"
  # Restore first to avoid double-patching across iOS → macOS sequence.
  git checkout -- app/Shared/ContentView.swift
  sed -i '' "s|Text(\"$ORIGINAL_SUBTITLE\")|Text(\"$new_label\")|g" app/Shared/ContentView.swift
  grep -q "Text(\"$new_label\")" app/Shared/ContentView.swift || \
    fail "subtitle patch did not land — '$new_label' not found post-sed"
  ok "subtitle patched to '$new_label'"
}

regenerate_project() {
  ( cd app && xcodegen generate >/dev/null )
  ok "xcodegen generate complete"
}

# ── iOS ─────────────────────────────────────────────────────────────────────
if [ "$DO_IOS" = 1 ]; then
  step "iOS — capture 'iOS template' subtitle"

  patch_subtitle "iOS template"
  regenerate_project

  IOS_DEVICE="iPhone 16 Pro"
  IOS_RUNTIME=$(xcrun simctl list devices available 2>/dev/null \
    | awk -v dev="$IOS_DEVICE" '/^-- iOS / { rt=$0 } $0 ~ dev { print rt; exit }' | head -1)
  ok "using $IOS_DEVICE on $IOS_RUNTIME"

  # BSD-portable: grep the first matching device line, sed-extract UUID.
  IOS_DEVICE_ID=$(xcrun simctl list devices available 2>/dev/null \
    | grep "    $IOS_DEVICE (" | head -1 | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/')
  [ -n "$IOS_DEVICE_ID" ] || fail "could not resolve simulator UUID for '$IOS_DEVICE'"
  ok "device UUID: $IOS_DEVICE_ID"

  step "Booting simulator + building HelloApp-iOS"
  xcrun simctl bootstatus "$IOS_DEVICE_ID" -b >/dev/null 2>&1 || true
  xcrun simctl boot "$IOS_DEVICE_ID" 2>/dev/null || true   # idempotent (already-booted is fine)
  xcrun simctl bootstatus "$IOS_DEVICE_ID" >/dev/null

  DERIVED_DATA="$(mktemp -d -t shipkit-screenshot-iosDD-XXXXXX)"
  xcodebuild build \
    -project app/HelloApp.xcodeproj \
    -scheme HelloApp-iOS \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$IOS_DEVICE_ID" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    > /tmp/regen-screenshot-ios-build.log 2>&1 \
    || { cat /tmp/regen-screenshot-ios-build.log; fail "iOS build failed"; }
  ok "iOS build succeeded"

  IOS_APP_PATH=$(find "$DERIVED_DATA/Build/Products/Debug-iphonesimulator" -name 'HelloApp-iOS.app' -type d -print -quit)
  [ -n "$IOS_APP_PATH" ] || fail "could not locate HelloApp-iOS.app post-build"

  step "Installing + launching HelloApp on simulator"
  xcrun simctl install  "$IOS_DEVICE_ID" "$IOS_APP_PATH"
  xcrun simctl launch   "$IOS_DEVICE_ID" "com.example.helloapp" >/dev/null
  sleep 3   # let the app render fully

  step "Capturing iOS screenshot → docs/screenshots/ios-home.png"
  xcrun simctl io "$IOS_DEVICE_ID" screenshot docs/screenshots/ios-home.png
  ok "saved $(file docs/screenshots/ios-home.png | sed 's|docs/screenshots/ios-home.png:||')"

  xcrun simctl terminate "$IOS_DEVICE_ID" "com.example.helloapp" 2>/dev/null || true
  rm -rf "$DERIVED_DATA"
fi

# ── macOS ───────────────────────────────────────────────────────────────────
if [ "$DO_MACOS" = 1 ]; then
  step "macOS — capture 'macOS template' subtitle"

  patch_subtitle "macOS template"
  regenerate_project

  step "Building HelloApp-macOS"
  DERIVED_DATA="$(mktemp -d -t shipkit-screenshot-macDD-XXXXXX)"
  xcodebuild build \
    -project app/HelloApp.xcodeproj \
    -scheme HelloApp-macOS \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_IDENTITY="-" \
    > /tmp/regen-screenshot-macos-build.log 2>&1 \
    || { cat /tmp/regen-screenshot-macos-build.log; fail "macOS build failed"; }
  ok "macOS build succeeded"

  MACOS_APP_PATH=$(find "$DERIVED_DATA/Build/Products/Debug" -name 'HelloApp-macOS.app' -type d -print -quit)
  [ -n "$MACOS_APP_PATH" ] || fail "could not locate HelloApp-macOS.app post-build (macOS)"

  step "Launching macOS app + capturing window"
  open "$MACOS_APP_PATH"
  sleep 4   # let the app fully launch + render

  # Find the HelloApp window via osascript, get its window ID, then
  # screencapture -l<windowID>. Fallback: capture the entire screen if
  # window ID resolution fails.
  WINDOW_ID=""
  WINDOW_ID=$(osascript <<'OSASCRIPT' 2>/dev/null || true
tell application "System Events"
  tell process "HelloApp"
    set windowID to id of window 1
    return windowID
  end tell
end tell
OSASCRIPT
  )

  if [ -n "$WINDOW_ID" ] && [ "$WINDOW_ID" != "0" ]; then
    screencapture -l "$WINDOW_ID" -t png docs/screenshots/macos-home.png
    ok "captured window id=$WINDOW_ID"
  else
    # Fallback: ask osascript for window bounds + region-capture.
    BOUNDS=$(osascript <<'OSASCRIPT' 2>/dev/null || true
tell application "System Events"
  tell process "HelloApp"
    set b to position of window 1
    set s to size of window 1
    set x to item 1 of b
    set y to item 2 of b
    set w to item 1 of s
    set h to item 2 of s
    return (x as text) & "," & (y as text) & "," & (w as text) & "," & (h as text)
  end tell
end tell
OSASCRIPT
    )
    if [ -n "$BOUNDS" ]; then
      IFS=',' read -r WX WY WW WH <<< "$BOUNDS"
      screencapture -R "$WX,$WY,$WW,$WH" -t png docs/screenshots/macos-home.png
      ok "captured region $BOUNDS"
    else
      fail "could not resolve window id or bounds; capture HelloApp manually + save to docs/screenshots/macos-home.png"
    fi
  fi
  ok "saved $(file docs/screenshots/macos-home.png | sed 's|docs/screenshots/macos-home.png:||')"

  # Quit the app gracefully so we leave the user's Dock clean.
  osascript -e 'tell application "HelloApp" to quit' 2>/dev/null || true
  rm -rf "$DERIVED_DATA"
fi

# ── Restore ContentView.swift ───────────────────────────────────────────────
restore_content_view
trap - EXIT INT TERM

# Re-generate project so the working tree matches the restored source.
( cd app && xcodegen generate >/dev/null ) || true

step "Done. Review changes:"
echo "  git status --short"
echo "  ls -la docs/screenshots/"
ls -la docs/screenshots/ios-home.png docs/screenshots/macos-home.png 2>/dev/null
