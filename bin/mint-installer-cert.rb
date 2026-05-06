#!/usr/bin/env ruby
# bin/mint-installer-cert.rb
#
# Mints a Mac Installer Distribution cert directly via the App Store Connect
# API, bypassing fastlane match's `cert` action. Why bypass:
#   - fastlane match's `cert` action mis-routes when given
#     `mac_installer_distribution` and reports DISTRIBUTION cert limit errors
#     even when iOS Distribution slots are full (different cert bucket).
#   - fastlane `produce` action requires Apple ID + 2FA for certain ASC API
#     paths; we deliberately don't carry those credentials in CI.
#
# What this does:
#   1. Reads ASC API creds from env (ASC_API_KEY_ID / ISSUER_ID /
#      P8_BASE64).
#   2. Optionally revokes any existing MAC_INSTALLER_DISTRIBUTION certs to
#      free a slot (cert action limits at 2/team). Pass --keep-existing to
#      skip revocation.
#   3. Generates a fresh CSR + private key locally.
#   4. POSTs to ASC to mint a new MAC_INSTALLER_DISTRIBUTION cert.
#   5. Writes .cer (signed cert from ASC) and .p12 (cert + private key
#      bundle) to /tmp/HelloApp-Installer-<cert-id>.{cer,p12}.
#
# What you do next:
#   ./bin/import-installer-to-match.rb
#
# This wraps the .p12 in a match-compatible blob, encrypts it, and pushes
# it to your certs repo so CI can fetch it readonly.
#
# Required env vars (set via `~/.config/secrets.env` or similar):
#   ASC_API_KEY_ID         - ASC API key id
#   ASC_API_KEY_ISSUER_ID  - ASC API key issuer UUID
#   ASC_API_KEY_P8_BASE64  - base64 of the .p8 file contents
#
# Usage:
#   set -a; source ~/.config/secrets.env; set +a
#   bundle exec ruby bin/mint-installer-cert.rb
#   bundle exec ruby bin/mint-installer-cert.rb --keep-existing  # don't revoke

require 'fastlane'
require 'fastlane_core'
require 'spaceship'
require 'openssl'
require 'base64'

KEEP_EXISTING = ARGV.include?("--keep-existing")

# Build ASC API token directly from env (no fastlane action wrapper needed).
key_content_pem = Base64.decode64(ENV.fetch("ASC_API_KEY_P8_BASE64"))
Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.create(
  key_id:    ENV.fetch("ASC_API_KEY_ID"),
  issuer_id: ENV.fetch("ASC_API_KEY_ISSUER_ID"),
  key:       key_content_pem,
  duration:  1200,
  in_house:  false,
)

# 1. Optionally revoke existing MAC_INSTALLER_DISTRIBUTION certs.
existing = Spaceship::ConnectAPI::Certificate.all.select do |c|
  c.certificate_type == Spaceship::ConnectAPI::Certificate::CertificateType::MAC_INSTALLER_DISTRIBUTION
end

if existing.any?
  if KEEP_EXISTING
    puts "Keeping #{existing.size} existing MAC_INSTALLER_DISTRIBUTION cert(s) (--keep-existing)"
    existing.each { |c| puts "  #{c.id} expires #{c.expiration_date}" }
    abort "Apple limits MAC_INSTALLER_DISTRIBUTION at 2/team. Re-run without --keep-existing if minting fails." if existing.size >= 2
  else
    existing.each do |c|
      puts "Revoking existing MAC_INSTALLER_DISTRIBUTION cert: #{c.id}"
      Spaceship::ConnectAPI.delete_certificate(certificate_id: c.id)
    end
  end
end

# 2. Generate CSR + private key locally.
csr, pkey = Spaceship::ConnectAPI::Certificate.create_certificate_signing_request

# 3. POST to ASC API to mint the cert.
puts "Minting MAC_INSTALLER_DISTRIBUTION cert via ASC API…"
cert = Spaceship::ConnectAPI::Certificate.create(
  certificate_type: Spaceship::ConnectAPI::Certificate::CertificateType::MAC_INSTALLER_DISTRIBUTION,
  csr_content:      csr.to_pem,
)
puts "  ✓ minted cert id=#{cert.id} expires=#{cert.expiration_date}"

# 4. Build .cer + .p12 files. .cer is the DER-encoded signed certificate
#    that ASC just returned (cert.certificate_content is base64-encoded). .p12
#    bundles the cert with our private key for keychain import.
cer_der_bytes = Base64.decode64(cert.certificate_content)
x509          = OpenSSL::X509::Certificate.new(cer_der_bytes)

# Empty p12 password (match's default; matches what `fastlane match` mints).
# The .p12 itself is encrypted via match's MATCH_PASSWORD when imported into
# the certs repo, so the inner p12 password is unused.
p12 = OpenSSL::PKCS12.create(nil, "match-installer-#{cert.id}", pkey, x509)

cer_path = "/tmp/HelloApp-Installer-#{cert.id}.cer"
p12_path = "/tmp/HelloApp-Installer-#{cert.id}.p12"
File.binwrite(cer_path, cer_der_bytes)
File.binwrite(p12_path, p12.to_der)
File.chmod(0o600, p12_path)

puts ""
puts "Wrote:"
puts "  #{cer_path}"
puts "  #{p12_path}"
puts ""
puts "Cert id: #{cert.id}"
puts "Persist this to your env so the import script picks it up:"
puts "  export INSTALLER_CERT_ID=#{cert.id}"
puts ""
puts "Next:  bundle exec ruby bin/import-installer-to-match.rb"
