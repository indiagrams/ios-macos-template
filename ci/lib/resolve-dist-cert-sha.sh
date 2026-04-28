# Apple Distribution cert SHA-1 resolver — shared across indiagrams release pipelines.
#
# DO NOT EDIT DIVERGENTLY. Identical copies live in:
#   - github.com/indiagrams/PrivateClaw  ci/lib/resolve-dist-cert-sha.sh
#   - github.com/indiagrams/AnchorKey    ci/lib/resolve-dist-cert-sha.sh
#
# Any new project signing for Apple Developer team A26TJZ8QHQ should copy this
# file as-is. When you change one project's copy, update the other(s) in the
# same release cycle. `make verify-helpers-in-sync` (in each repo) compares
# the local copy against a canonical SHA-256 — CI fails if they drift.
#
# WHY THIS EXISTS
# ---------------
# The `Apple Distribution: <name> (<team-id>)` common name is shared across
# every Apple Distribution cert issued to that team. When a developer machine
# carries certs for multiple apps (e.g. PrivateClaw + AnchorKey under the same
# personal team), `codesign --sign "Apple Distribution"` and exportArchive's
# `signingCertificate: "Apple Distribution"` both become ambiguous and pick
# one randomly. Symptoms:
#   - exportArchive: "Provisioning profile X doesn't include signing
#     certificate Y" (it picked the cert from the other project)
#   - codesign:      "Apple Distribution: ambiguous (matches A and B in
#     login.keychain-db)"
#
# Pin to the exact SHA-1 listed in the App Store distribution profile
# (`DeveloperCertificates` field of the .mobileprovision/.provisionprofile
# plist). That SHA-1 is project-specific and stable across cert rotations
# as long as the profile is up to date.
#
# USAGE
# -----
#   . ci/lib/resolve-dist-cert-sha.sh
#
#   # Pre-build path (when you know the profile name; needed for iOS
#   # exportArchive's ExportOptions.plist signingCertificate field):
#   sha=$(resolve_dist_cert_sha_from_profile_name "Butler iOS App Store Distribution")
#
#   # Post-build path (more reliable; reads the profile actually embedded in
#   # the built .app — guaranteed to match what Xcode chose at archive time):
#   sha=$(resolve_dist_cert_sha_from_app "$EXPANDED_APP")
#
# Both functions echo the SHA-1 (uppercase hex) to stdout on success.
# On failure they echo a diagnostic to stderr and return non-zero — callers
# should `set -e` or check the exit code; this library does not call `exit`
# so it stays composable.

# Internal: extract the SHA-1 of the first DeveloperCertificate from a
# .mobileprovision / .provisionprofile file path.
__rdcs_sha_from_path() {
  local prof_path="$1"
  if [ ! -f "$prof_path" ]; then
    echo "resolve-dist-cert-sha: profile file not found: $prof_path" >&2
    return 1
  fi
  local sha
  sha=$(security cms -D -i "$prof_path" 2>/dev/null | python3 -c "
import sys, plistlib, hashlib
try:
    p = plistlib.loads(sys.stdin.buffer.read())
except Exception as e:
    sys.stderr.write(f'resolve-dist-cert-sha: parse error: {e}\n')
    sys.exit(1)
certs = p.get('DeveloperCertificates', [])
if not certs:
    sys.stderr.write('resolve-dist-cert-sha: no DeveloperCertificates in profile\n')
    sys.exit(1)
print(hashlib.sha1(certs[0]).hexdigest().upper())
")
  if [ -z "$sha" ]; then
    return 1
  fi
  if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$sha"; then
    echo "resolve-dist-cert-sha: cert $sha listed in $prof_path is not in keychain — re-download cert + profile from developer.apple.com" >&2
    return 1
  fi
  printf '%s' "$sha"
}

# Resolve cert SHA-1 by provisioning-profile name.
# Searches ~/Library/Developer/Xcode/UserData/Provisioning Profiles/*.mobileprovision
# for one whose Name field matches.
#
# Args:
#   $1  profile name (e.g. "Butler iOS App Store Distribution")
resolve_dist_cert_sha_from_profile_name() {
  local prof_name="$1"
  if [ -z "$prof_name" ]; then
    echo "resolve_dist_cert_sha_from_profile_name: profile name is required" >&2
    return 2
  fi
  local prof_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  if [ ! -d "$prof_dir" ]; then
    echo "resolve_dist_cert_sha_from_profile_name: profile directory not found: $prof_dir" >&2
    return 1
  fi
  local prof_path=""
  local p name
  for p in "$prof_dir"/*.mobileprovision "$prof_dir"/*.provisionprofile; do
    [ -f "$p" ] || continue
    name=$(security cms -D -i "$p" 2>/dev/null \
      | python3 -c "import sys, plistlib; print(plistlib.loads(sys.stdin.buffer.read()).get('Name',''))" 2>/dev/null)
    if [ "$name" = "$prof_name" ]; then
      prof_path="$p"
      break
    fi
  done
  if [ -z "$prof_path" ]; then
    echo "resolve_dist_cert_sha_from_profile_name: profile '$prof_name' not found in $prof_dir" >&2
    return 1
  fi
  __rdcs_sha_from_path "$prof_path"
}

# Resolve cert SHA-1 from a built .app bundle's embedded provisioning profile.
# Reads embedded.mobileprovision (iOS) or Contents/embedded.provisionprofile
# (macOS) — whichever exists. This is the most reliable approach because it
# captures the cert Xcode actually chose at archive time.
#
# Args:
#   $1  path to .app bundle
resolve_dist_cert_sha_from_app() {
  local app="$1"
  if [ -z "$app" ] || [ ! -d "$app" ]; then
    echo "resolve_dist_cert_sha_from_app: not a directory: $app" >&2
    return 2
  fi
  local prof
  if [ -f "$app/embedded.mobileprovision" ]; then
    prof="$app/embedded.mobileprovision"          # iOS bundle layout
  elif [ -f "$app/Contents/embedded.provisionprofile" ]; then
    prof="$app/Contents/embedded.provisionprofile"  # macOS bundle layout
  else
    echo "resolve_dist_cert_sha_from_app: no embedded provisioning profile in $app" >&2
    return 1
  fi
  __rdcs_sha_from_path "$prof"
}
