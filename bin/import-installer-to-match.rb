#!/usr/bin/env ruby
# bin/import-installer-to-match.rb
#
# Imports a previously-minted MAC_INSTALLER_DISTRIBUTION cert (.cer + .p12)
# into the match-encrypted certs repo. Bypasses the interactive prompts that
# `fastlane match import` CLI uses by calling Match::Importer directly.
#
# Pair with bin/mint-installer-cert.rb. Run order:
#   bundle exec ruby bin/mint-installer-cert.rb
#   export INSTALLER_CERT_ID=<id-printed-by-mint-script>
#   bundle exec ruby bin/import-installer-to-match.rb
#
# Required env vars:
#   INSTALLER_CERT_ID              - ASC cert id (from mint script output)
#   ASC_API_KEY_ID                 - ASC API key id
#   ASC_API_KEY_ISSUER_ID          - ASC API key issuer UUID
#   ASC_API_KEY_P8_BASE64          - base64 of the .p8 file contents
#   MATCH_PASSWORD                 - certs repo encryption passphrase
#   MATCH_GIT_BASIC_AUTHORIZATION  - base64(<gh-user>:<PAT>) for repo write
#
# After this succeeds, CI's `match mac_installer_distribution --readonly`
# will fetch and install the cert without minting anything. The cert is
# encrypted with MATCH_PASSWORD before being pushed.

require 'fastlane'
require 'match'
require 'fastlane_core'
require 'base64'

CERT_ID  = ENV.fetch("INSTALLER_CERT_ID") do
  abort "INSTALLER_CERT_ID env var required (from bin/mint-installer-cert.rb output)"
end
CERT_PATH = "/tmp/HelloApp-Installer-#{CERT_ID}.cer"
P12_PATH  = "/tmp/HelloApp-Installer-#{CERT_ID}.p12"

raise "Missing #{CERT_PATH} — re-run bin/mint-installer-cert.rb first" unless File.exist?(CERT_PATH)
raise "Missing #{P12_PATH} — re-run bin/mint-installer-cert.rb first" unless File.exist?(P12_PATH)

# Read the certs repo URL from Matchfile (so the maintainer doesn't have to
# duplicate it here).
matchfile_path = File.expand_path("../fastlane/Matchfile", __dir__)
abort "Missing #{matchfile_path}" unless File.exist?(matchfile_path)
git_url_line = File.readlines(matchfile_path).find { |l| l.match?(/^\s*git_url\(/) }
abort "Could not find git_url(...) in Matchfile" unless git_url_line
git_url = git_url_line[/git_url\(["']([^"']+)["']\)/, 1]
abort "git_url(...) in Matchfile parsed empty" unless git_url
abort "Matchfile still has placeholder URL — set git_url(...) to your real certs repo" if git_url.include?("CHANGE-ME")

app_identifier_line = File.readlines(matchfile_path).find { |l| l.match?(/^\s*app_identifier\(/) }
app_identifier = app_identifier_line[/\["([^"]+)"\]/, 1] if app_identifier_line
abort "Could not parse app_identifier from Matchfile" unless app_identifier

# Build match's params hash. Mirrors what the CLI flags would produce.
params = FastlaneCore::Configuration.create(
  Match::Options.available_options,
  {
    type:                       "mac_installer_distribution",
    platform:                   "macos",
    app_identifier:             [app_identifier],
    storage_mode:               "git",
    git_url:                    git_url,
    git_basic_authorization:    ENV.fetch("MATCH_GIT_BASIC_AUTHORIZATION"),
    git_branch:                 "master",
    skip_provisioning_profiles: true,
    skip_certificate_matching:  false,
    force_legacy_encryption:    true,
    api_key: {
      key_id:    ENV.fetch("ASC_API_KEY_ID"),
      issuer_id: ENV.fetch("ASC_API_KEY_ISSUER_ID"),
      key:       Base64.decode64(ENV.fetch("ASC_API_KEY_P8_BASE64")),
      duration:  1200,
      in_house:  false,
    },
  }
)

ENV["MATCH_PASSWORD"] = ENV.fetch("MATCH_PASSWORD")

puts "Importing #{CERT_ID} into match certs repo (encrypted, V1)…"
Match::Importer.new.import_cert(params,
  cert_path: CERT_PATH,
  p12_path:  P12_PATH,
  profile_path: "")  # explicit empty avoids interactive prompt
puts "Done."
puts ""
puts "Verify:"
puts "  bundle exec fastlane match mac_installer_distribution --readonly --platform macos --app_identifier #{app_identifier} --skip_provisioning_profiles true"
