#!/usr/bin/env bash
# bin/preflight.sh — verify + auto-install prereqs for ios-macos-template forks.
#
# Idempotent. Run repeatedly; only acts on what's missing.
#
# Auto-installs (with confirmation): Homebrew, gh CLI, bundler.
# Auto-fixes (with confirmation): xcode-select dev dir, Xcode license.
# Cannot auto-install: Xcode (Mac App Store), Apple Developer membership.
#
# Usage:
#   bin/preflight.sh                # interactive; prompts before each install
#   bin/preflight.sh --yes          # auto-confirm all install/fix prompts
#
# Exit codes:
#   0 — all prereqs satisfied
#   1 — one or more prereqs missing AND user declined to fix
#   2 — Xcode not installed (manual install required from Mac App Store)

set -euo pipefail

YES=0
[ "${1:-}" = "--yes" ] && YES=1

step()  { printf '\n==> %s\n' "$*"; }
ok()    { printf '    ✓ %s\n' "$*"; }
warn()  { printf '    ⚠ %s\n' "$*" >&2; }
fail()  { printf '    ✗ %s\n' "$*" >&2; exit 1; }

ask() {
  local q="$1"
  [ "$YES" = "1" ] && return 0
  printf '    > %s [y/N] ' "$q"
  read -r ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ── 1. macOS check ──────────────────────────────────────────────
step "1/8: macOS"
if [ "$(uname -s)" != "Darwin" ]; then
  fail "macOS required (got $(uname -s)). Xcode only runs on macOS."
fi
ok "macOS $(sw_vers -productVersion)"

# ── 2. Xcode app installed ──────────────────────────────────────
step "2/8: Xcode (full app)"
if [ ! -d /Applications/Xcode.app ]; then
  warn "Xcode not found at /Applications/Xcode.app"
  echo "    Install Xcode from the Mac App Store (~10-15 GB, 30-60 min download)."
  echo "    https://apps.apple.com/us/app/xcode/id497799835"
  echo "    Then: open Xcode once to accept the launch dialog, and re-run this script."
  exit 2
fi
XCODE_VER=$(defaults read /Applications/Xcode.app/Contents/Info CFBundleShortVersionString 2>/dev/null || echo "unknown")
ok "Xcode $XCODE_VER at /Applications/Xcode.app"

# ── 3. xcode-select pointing at Xcode ──────────────────────────
step "3/8: xcode-select active developer directory"
ACTIVE=$(xcode-select -p 2>/dev/null || echo "")
if [[ "$ACTIVE" == */CommandLineTools ]] || [ -z "$ACTIVE" ]; then
  warn "xcode-select points at: ${ACTIVE:-<unset>}"
  echo "    Need: /Applications/Xcode.app/Contents/Developer"
  if ask "Run sudo xcode-select -s now?"; then
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
    ok "xcode-select switched"
  else
    fail "xcode-select must point at Xcode. Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  fi
fi
ok "xcode-select: $(xcode-select -p)"

# ── 4. Xcode license accepted ──────────────────────────────────
step "4/8: Xcode license"
if ! /usr/bin/xcrun --find xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  warn "Xcode license not accepted (xcodebuild can't run)"
  if ask "Run sudo xcodebuild -license accept now?"; then
    sudo xcodebuild -license accept
    ok "Xcode license accepted"
  else
    fail "Xcode license must be accepted. Run: sudo xcodebuild -license accept"
  fi
fi
ok "Xcode license accepted"

# ── 5. Homebrew ────────────────────────────────────────────────
step "5/8: Homebrew"
if ! command -v brew >/dev/null 2>&1; then
  warn "Homebrew not installed"
  echo "    Required for: make bootstrap (xcodegen, fastlane, lefthook from Brewfile)"
  if ask "Install Homebrew now? (downloads + runs official install script from brew.sh)"; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Try common Homebrew paths so brew is on PATH this session
    if [ -x /opt/homebrew/bin/brew ]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
    ok "Homebrew installed"
  else
    fail "Homebrew required. See https://brew.sh"
  fi
fi
ok "Homebrew $(brew --version | head -1 | awk '{print $2}')"

# ── 6. gh CLI installed ────────────────────────────────────────
step "6/8: gh CLI installed"
if ! command -v gh >/dev/null 2>&1; then
  warn "gh CLI not installed"
  if ask "Install via brew install gh?"; then
    brew install gh
    ok "gh installed"
  else
    fail "gh required for gh repo create + bin/setup-github.sh"
  fi
fi
ok "gh $(gh --version | head -1 | awk '{print $3}')"

# ── 7. gh authenticated ────────────────────────────────────────
step "7/8: gh authenticated"
if ! gh auth status >/dev/null 2>&1; then
  warn "gh not authenticated"
  echo "    gh auth login walks you through browser-based or token-based login"
  if ask "Run gh auth login now?"; then
    gh auth login
    ok "gh authenticated"
  else
    fail "gh must be authenticated. Run: gh auth login"
  fi
fi
GH_USER=$(gh api user --jq .login 2>/dev/null || echo "?")
ok "gh authenticated as $GH_USER"

# ── 8. Bundler (for fastlane Ruby gems) ───────────────────────
step "8/8: Bundler (for fastlane)"
if ! command -v bundle >/dev/null 2>&1; then
  warn "Bundler not installed"
  if ask "Install via gem install bundler? (uses macOS system Ruby)"; then
    sudo gem install bundler
    ok "Bundler installed"
  else
    warn "Bundler is required for make bootstrap (Ruby gems for fastlane)"
    fail "Install bundler manually: sudo gem install bundler"
  fi
fi
ok "Bundler $(bundle --version | awk '{print $3}')"

# ── Summary ────────────────────────────────────────────────────
step "All preflight checks passed"
cat <<'EOF'

  Next steps:

    1. (Optional) Read docs/APPLE-PREREQS.md if you plan to ship to TestFlight or
       the App Store — covers what tier of Apple Developer account you need.

    2. Quickstart from a fresh fork:

         gh repo create my-app --template indiagrams/ios-macos-template --public --clone && cd my-app
         bin/rename.sh YourApp com.your-org.yourapp 'Your App' --email=you@example.com
         make bootstrap
         make check

EOF
