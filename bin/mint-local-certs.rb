#!/usr/bin/env ruby
# frozen_string_literal: true

# Mint any missing local-mode signing identities (Apple Distribution,
# Apple Development, 3rd Party Mac Developer Installer) into the user's
# login keychain. Idempotent — fastlane cert detects existing valid certs
# and reuses rather than minting duplicates.
#
# Used by `make mint-local-certs`. Same code path as
# `make bootstrap-fork`'s LocalKeychainCerts step.
#
# Usage: bundle exec ruby bin/mint-local-certs.rb

require_relative "lib/bootstrap"

config = Bootstrap::Config.load!
config.validate!

if config.ci_mode?
  Bootstrap::UI.fail!(
    "make mint-local-certs is local-mode-only; this fork has RELEASE_MODE=ci.\n" \
    "In CI mode, fastlane match handles cert provisioning on the runner — there's\n" \
    "nothing to mint locally."
  )
end

step = Bootstrap::LocalKeychainCerts.new(config)
needed = (step.missing_identities + step.team_mismatched_identities).uniq

if needed.empty?
  Bootstrap::UI.section "All local-mode signing identities present"
  puts "  Nothing to mint. Run `make doctor` to see the full pipeline status."
  exit 0
end

step.do_it
puts
puts Bootstrap::UI.bold("Done. Run `make doctor` to verify.")
