#!/bin/bash
# ci/take-screenshots.sh — capture App Store screenshots (iOS + macOS).
#
# iOS uses fastlane snapshot (Snapfile). macOS uses xcodebuild test +
# extract-mac-screenshots.sh (fastlane snapshot is iOS-only).
#
# Usage:
#   ci/take-screenshots.sh                    # iOS + macOS, no upload
#   ci/take-screenshots.sh --upload           # iOS + macOS, then upload to ASC
#   ci/take-screenshots.sh --ios-only         # skip macOS
#   ci/take-screenshots.sh --macos-only       # skip iOS
#
# Output: fastlane/screenshots/en-US/*.png  (flat — deliver only globs en-US/*.png
# and a few hardcoded subdirectories; arbitrary subfolders are silently ignored)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

UPLOAD=false
IOS_ONLY=false
MACOS_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --upload)      UPLOAD=true ;;
    --ios-only)    IOS_ONLY=true ;;
    --macos-only)  MACOS_ONLY=true ;;
    -h|--help)
      sed -n 's/^# \?//p' "$0" | head -25
      exit 0
      ;;
    *)
      echo "error: unknown arg '$arg'" >&2
      exit 2
      ;;
  esac
done

# brew Ruby — fastlane via system Ruby fails on bundler version mismatch
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"

step()   { printf '\n==> %s\n' "$*"; }
ok()     { printf '    ✓ %s\n' "$*"; }

step "xcodegen generate"
( cd app && xcodegen generate >/dev/null )
ok "app/HelloApp.xcodeproj refreshed"

if ! $MACOS_ONLY; then
  step "Capture iOS screenshots (fastlane/Snapfile)"
  bundle exec fastlane snapshot
  ok "iOS done — see fastlane/screenshots/en-US/*.png"
fi

if ! $IOS_ONLY; then
  step "Capture macOS screenshots (xcodebuild test)"
  XCRESULT="/tmp/mac-screenshots.xcresult"
  rm -rf "$XCRESULT"
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
    -project app/HelloApp.xcodeproj \
    -scheme HelloApp-macOS \
    -destination 'platform=macOS' \
    -resultBundlePath "$XCRESULT" \
    -only-testing:HelloAppMacOSUITests/AppStoreScreenshotTests \
    ONLY_ACTIVE_ARCH=YES 2>&1 | xcbeautify --quiet || {
      echo "error: macOS screenshot test failed — see $XCRESULT" >&2
      exit 1
    }
  ./ci/extract-mac-screenshots.sh "$XCRESULT"
  ok "macOS done — see fastlane/screenshots/en-US/macos-*.png"
fi

if $UPLOAD; then
  step "Upload screenshots to App Store Connect"
  bundle exec fastlane ios upload_screenshots
  bundle exec fastlane mac upload_screenshots
  ok "uploaded"
fi

step "Done"
ok "Inspect fastlane/screenshots/ then either:"
ok "  • commit them, or"
ok "  • run ci/take-screenshots.sh --upload to push to ASC, or"
ok "  • run fastlane ios/mac submit_for_review when build is 'Ready for Review'"
