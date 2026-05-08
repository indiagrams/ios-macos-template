#!/usr/bin/env ruby
# frozen_string_literal: true

# Audit local login.keychain against Apple's valid-cert list and (with
# confirmation) delete the locally-cached certs that Apple no longer lists
# as valid.
#
# Why this exists: xcodebuild's CODE_SIGN_IDENTITY=Apple Distribution does
# substring matching against the keychain. If your login keychain has
# multiple matching certs and one is revoked at Apple's side (still locally
# cached), xcodebuild can pick the revoked one and fail the archive with:
#   error: Signing certificate is invalid. ... It may have been revoked or
#   expired.
# `security find-identity -v` doesn't filter revoked-at-Apple certs (only
# locally-expired ones). This script uses ASC API to query Apple's view of
# valid certs, diffs against your keychain, and deletes the stale ones.
#
# Usage:
#   bundle exec ruby bin/clean-revoked-certs.rb              # interactive prompt
#   bundle exec ruby bin/clean-revoked-certs.rb --yes        # delete without prompt
#   bundle exec ruby bin/clean-revoked-certs.rb --dry-run    # show diff but don't delete
#
# Used by: `make clean-revoked-certs`. Loads `.bootstrap.env`, sets the
# ASC_API_KEY_* env vars via Bootstrap.asc_env, invokes the
# `clean_revoked_certs` fastlane lane.

require_relative "lib/bootstrap"

# Forward CLI flags as fastlane lane options
flags = []
ARGV.each do |arg|
  case arg
  when "--yes"     then flags << "yes:true"
  when "--dry-run" then flags << "dry_run:true"
  when "--help", "-h"
    puts <<~HELP
      Usage: bundle exec ruby bin/clean-revoked-certs.rb [--yes|--dry-run]

      Diffs local Apple-signing certs against Apple's valid-cert list. Deletes
      revoked locally-cached certs that xcodebuild might pick by mistake.

      Modes:
        (default)  Interactive — list revoked certs, prompt before deletion
        --yes      Non-interactive — delete all revoked certs without prompting
        --dry-run  List revoked certs but don't delete (preview)
    HELP
    exit 0
  else
    Bootstrap::UI.fail!("unknown arg: #{arg}. Try --help.")
  end
end

config = Bootstrap::Config.load!
config.validate!

env = Bootstrap.asc_env(config)
# Use Kernel.system (NOT Sh.run!) so fastlane's output streams to the
# terminal in real time and UI.confirm prompts can read user input. Sh.run!
# captures stdout/stdin via Open3.capture3, which would hide the cert list
# AND deadlock the prompt.
env.each { |k, v| ENV[k] = v }
ok = Kernel.system("bundle", "exec", "fastlane", "clean_revoked_certs", *flags)
exit(ok ? 0 : 1)
