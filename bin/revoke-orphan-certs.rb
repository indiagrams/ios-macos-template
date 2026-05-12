#!/usr/bin/env ruby
# frozen_string_literal: true

# Audit Apple's valid-cert list against the user's login.keychain and (with
# confirmation) revoke the Apple-side distribution certs whose private keys
# live nowhere on the user's Mac.
#
# Why this exists: Apple caps distribution certs at 3 per team. Each CI release
# run mints a fresh cert and revokes it in an `if: always()` post-step, but the
# post-step can be skipped (runner evicted mid-run, hard crash, cache-evicted
# tracking file >7 days idle). Over time, the team accumulates Apple-side cert
# IDs whose private keys live nowhere. The next release run then hits
#   [!] Could not create another Distribution certificate, reached the maximum
#       number of available Distribution certificates.
# at the minting step. Previously the only recovery was the developer.apple.com
# web UI (~30 sec but error-prone — easy to revoke a cert that IS in use
# elsewhere). This script makes the recovery local + scriptable + safe.
#
# Safety guard: only certs whose serial number is NOT present in
# ~/Library/Keychains/login.keychain-db are flagged. If your Mac has the cert,
# you can use it for signing somewhere — so it's not an orphan and won't be
# touched.
#
# Usage:
#   bundle exec ruby bin/revoke-orphan-certs.rb              # interactive prompt
#   bundle exec ruby bin/revoke-orphan-certs.rb --yes        # revoke without prompt
#   bundle exec ruby bin/revoke-orphan-certs.rb --dry-run    # list orphans, don't revoke
#
# Used by: `make revoke-orphan-certs`. Loads `.bootstrap.env`, sets the
# ASC_API_KEY_* env vars via Bootstrap.asc_env, invokes the
# `revoke_orphan_certs` fastlane lane.

require_relative "lib/bootstrap"

# Forward CLI flags as fastlane lane options
flags = []
ARGV.each do |arg|
  case arg
  when "--yes", "-y"
    flags << "yes:true"
  when "--dry-run", "-n"
    flags << "dry_run:true"
  when "--help", "-h"
    puts <<~USAGE
      Usage: bundle exec ruby bin/revoke-orphan-certs.rb [--yes] [--dry-run]

      Revoke Apple-side distribution certs whose private keys are not present
      in your local login.keychain. Only flags orphans — never revokes a cert
      whose private key exists on this Mac.

      Options:
        --yes, -y       Skip the confirmation prompt.
        --dry-run, -n   List orphans, don't revoke.
        --help, -h      Show this message.

      Driven by Makefile target `make revoke-orphan-certs`.
    USAGE
    exit 0
  else
    warn "unknown flag: #{arg}"
    exit 2
  end
end

config = Bootstrap::Config.load!
config.validate!

env = Bootstrap.asc_env(config)
# Use Kernel.system (NOT Sh.run!) so fastlane's output streams to the
# terminal in real time and UI.confirm prompts can read user input.
# Sh.run! captures stdout/stdin via Open3.capture3, which would hide the
# cert list AND deadlock the prompt. Same rationale as clean-revoked-certs.rb.
env.each { |k, v| ENV[k] = v }
ok = Kernel.system("bundle", "exec", "fastlane", "revoke_orphan_certs", *flags)
exit(ok ? 0 : 1)
