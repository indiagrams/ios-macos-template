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

# Pin Ruby to the version declared in `.ruby-version` so bundler finds the
# gems installed under `vendor/bundle/ruby/<MAJOR.MINOR>.0/`. Without
# this pin, brew's unversioned `/opt/homebrew/opt/ruby/bin` symlink
# moves with each new major Ruby release (May 2026: bumped from 3.3 to 4.0),
# silently breaking `bundle exec` for everyone using brew Ruby.
# `.ruby-version` is checked in alongside .tool-versions (per #175); the
# Brewfile installs `ruby@${MAJOR.MINOR}` to match.
RUBY_VER="$(cat "$REPO_ROOT/.ruby-version" 2>/dev/null || echo 3.3)"
RUBY_MM="$(echo "$RUBY_VER" | awk -F. '{ print $1 "." $2 }')"
if [ -d "/opt/homebrew/opt/ruby@${RUBY_MM}/bin" ]; then
  export PATH="/opt/homebrew/opt/ruby@${RUBY_MM}/bin:$PATH"
elif [ -d "/opt/homebrew/opt/ruby/bin" ]; then
  echo "WARN: brew ruby@${RUBY_MM} not installed; falling back to /opt/homebrew/opt/ruby (currently $(/opt/homebrew/opt/ruby/bin/ruby -v 2>/dev/null | awk '{print $2}')). Run \`brew install ruby@${RUBY_MM}\` if bundle exec fails." >&2
  export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
fi

step()   { printf '\n==> %s\n' "$*"; }
ok()     { printf '    ✓ %s\n' "$*"; }

# Generator-aware: detect xcodegen vs tuist from filesystem (mirrors
# the matrix builder in .github/workflows/pr.yml). Detecting at run-time
# keeps this script working across both generators — and across forks
# that flip generator via bin/switch-to-{tuist,xcodegen}.sh after the
# initial bin/rename.sh. App-name is read from the resulting .xcodeproj
# basename, so re-runs after rename Just Work too.
if [ -f app/project.yml ]; then
  step "xcodegen generate"
  ( cd app && xcodegen generate >/dev/null )
elif [ -f app/Project.swift ]; then
  step "tuist generate"
  ( cd app && tuist generate --no-open >/dev/null )
else
  echo "ERROR: neither app/project.yml (xcodegen) nor app/Project.swift (tuist) found in app/." >&2
  echo "       Run 'bin/switch-to-xcodegen.sh' or 'bin/switch-to-tuist.sh' to materialize one." >&2
  exit 1
fi
# Resolve app name from the resulting .xcodeproj basename — survives
# bin/rename.sh, switch-to-{tuist,xcodegen}.sh, and any other flow that
# emits app/<APP_NAME>.xcodeproj. Single .xcodeproj is the contract; if
# this ever changes, the explicit globbing here will fail loudly.
XCODEPROJ="$(ls -d app/*.xcodeproj 2>/dev/null | head -1)"
if [ -z "$XCODEPROJ" ]; then
  echo "ERROR: no .xcodeproj produced under app/ after generate. Bailing." >&2
  exit 1
fi
APP_NAME="$(basename "$XCODEPROJ" .xcodeproj)"
ok "${XCODEPROJ} refreshed (APP_NAME=${APP_NAME})"

if ! $MACOS_ONLY; then
  # fastlane snapshot only checks against simulators that already exist —
  # it doesn't auto-create from device types. Parse Snapfile's `devices()`
  # list and create any that aren't yet on the machine. Idempotent: existing
  # simulators are left alone. Required because Apple's pre-created
  # simulators trail behind device types; e.g. as of Xcode 26 the 12.9"
  # iPad Pro family is no longer pre-created (the 13" M4 replaced it as
  # the default), but the 12.9" device type IS available and produces the
  # 2048×2732 dimensions that legacy ASC App records (APP_IPAD_PRO_3GEN_129)
  # require.
  step "Ensure Snapfile simulators exist"
  available_runtime="$(xcrun simctl list runtimes 2>/dev/null | awk '/iOS [0-9]/{print $NF}' | tail -1)"
  if [ -z "$available_runtime" ]; then
    echo "ERROR: no iOS runtime installed; install one via Xcode → Settings → Components." >&2
    exit 1
  fi
  sed -n '/^devices(/,/^])/p' fastlane/Snapfile \
    | grep -oE '"[^"]+"' \
    | sed 's/^"//; s/"$//' \
    | while IFS= read -r dev; do
      [ -z "$dev" ] && continue
      if xcrun simctl list devices 2>&1 | grep -F " $dev (" >/dev/null 2>&1; then
        ok "  $dev (already exists)"
      elif xcrun simctl create "$dev" "$dev" "$available_runtime" >/dev/null 2>&1; then
        ok "  $dev (created on $available_runtime)"
      else
        echo "  ⚠ $dev — could not create (simctl rejected device type); fastlane snapshot may fail" >&2
      fi
    done

  step "Capture iOS screenshots (fastlane/Snapfile)"
  bundle exec fastlane snapshot
  ok "iOS done — see fastlane/screenshots/en-US/*.png"
fi

if ! $IOS_ONLY; then
  step "Capture macOS screenshots (xcodebuild test)"
  XCRESULT="/tmp/mac-screenshots.xcresult"
  rm -rf "$XCRESULT"
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
    -project "$XCODEPROJ" \
    -scheme "${APP_NAME}-macOS" \
    -destination 'platform=macOS' \
    -resultBundlePath "$XCRESULT" \
    -only-testing:"${APP_NAME}MacOSUITests/AppStoreScreenshotTests" \
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
