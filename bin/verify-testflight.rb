#!/usr/bin/env ruby
# frozen_string_literal: true

# Confirm the build that `make ship` just produced actually made it into
# App Store Connect — and that ALL platform variants (iOS + macOS, when
# both are active) are processed.
#
# Strategy: derive the expected marketing version from the latest local
# `v*` git tag (which `make ship` pushed), then server-side filter ASC's
# Build collection on that version. Each `make ship` produces a unique
# tag (`v#{Time.now.utc.strftime('%Y.%V.%H%M')}` in local mode; release
# tag pushed by release.yml in CI mode), so the version → match is
# deterministic and immune to upload-time races with concurrent shippers
# on the same bundle id (e.g. the smoketest's canary, which uploads
# every Saturday and would otherwise dominate `sort: -uploadedDate`).
#
# Falls back to "newest by uploaded date" only if no local v* tag is
# found (e.g. fresh fork that hasn't shipped yet, or user ran from a
# non-tagged worktree); prints a warning when this fallback engages.
#
# ASC indexes uploads asynchronously (~1-3 min after pilot returns).
# Tag exists but no matching build = "still indexing", not "failure" —
# we exit 2 with a "re-run in 1-2 min" hint, not a hard error.
#
# Usage: bundle exec ruby bin/verify-testflight.rb
#
# Exit:
#   0  build(s) matching the tag are processed (or processing — caller
#      can re-poll)
#   2  no matching build found (still indexing OR upload failed silently),
#      or any matching build is in a non-VALID/non-PROCESSING state, or
#      no builds at all for this app

require_relative "lib/bootstrap"

config = Bootstrap::Config.load!
config.validate!

require "spaceship"
Bootstrap.ensure_asc_token!(config)

app = Spaceship::ConnectAPI::App.find(config["BUNDLE_ID"])
unless app
  puts Bootstrap::UI.miss("ASC App record not found for #{config['BUNDLE_ID']}")
  puts "  Did you create it? See `make doctor` output."
  exit 2
end

# ─── Derive expected marketing version + build from latest local v* tag ──────
#
# Tag format conventions (apple-shipkit + forks):
#   v1.0.0+5                  — apple-shipkit v1.7+ (MARKETING+BUILD)
#   v0.1.0                    — historical / pre-CalVer
#   v1.5.0                    — apple-shipkit upstream releases
#   v2026.19.1214             — local mode pre-v1.7 (timestamp-as-marketing)
#   v0.YYYY.WW-canary-N-gen   — smoketest local-mode canary (#129/#134)
#
# Parser (Bootstrap::Version.parse_tag):
#   v1.0.0+5                  → marketing=1.0.0,        build=5
#   v0.YYYY.WW-canary-N-gen   → marketing=0.YYYY.WW,    build=nil
#   v2026.19.1214             → marketing=2026.19.1214, build=nil
#
# Run from the repo root (where the user invokes `make verify`); fall
# back gracefully if git fails (detached worktree, no tags yet, etc.).
#
# CI mode pushes the v* tag from the runner (release.yml's fastlane lane),
# not the user's local clone. Without a tag fetch, the local clone never
# sees it and verify falls back to "newest build" which dumps the whole
# bundle's history — useless when the user just ran `make ship` and wants
# to confirm THEIR build. Fetch tags from origin first; network-fail
# silently because the fallback path still runs if fetch fails.
system("git", "fetch", "--tags", "--quiet", "origin", out: File::NULL, err: File::NULL)

require_relative "lib/version_resolver"

expected_version = nil
expected_build = nil
latest_tag = nil

# `RELEASE_TAG` env override takes precedence over the git-tag lookup.
# Required by the smoketest's canary (canary-local-mode.yml) which uploads
# under an ephemeral CalVer tag (`v0.YYYY.WW-canary-N-gen`) that is
# deliberately NEVER pushed (`skip_tag:true` in the canary lane). The
# unpushed canary tag would never appear in `git tag --list 'v*'`; without
# the env override, this script falls through to "latest local tag" which
# on forks recently cut from upstream is the upstream release tag (e.g.
# `v1.7.0`), causing a tag mismatch — verify polls ASC for `1.7.0 (*)`
# while the canary uploaded `0.2026.20 (2102)`. Surfaced 2026-05-16 by
# the first Saturday cron after v1.7.0 was cut on the smoketest.
# Real-shipper use (`make verify` after `make ship`) still works via the
# git-tag fallback since `make ship` always pushes its tag.
override = ENV["RELEASE_TAG"].to_s.strip
if !override.empty?
  latest_tag = override
  expected_version, expected_build = Bootstrap::Version.parse_tag(latest_tag)
else
  begin
    raw = `git tag --sort=-creatordate --list 'v*' 2>/dev/null`.strip
    unless raw.empty?
      latest_tag = raw.lines.first.strip
      expected_version, expected_build = Bootstrap::Version.parse_tag(latest_tag)
    end
  rescue StandardError
    # leave nil; fallback engages below
  end
end

# ─── Fetch builds (filtered by version when known) ────────────────────────────
if expected_version
  matches = Spaceship::ConnectAPI::Build.all(
    app_id: app.id,
    version: expected_version,         # spaceship: `version:` filters CFBundleShortVersionString
    sort: "-uploadedDate",
    limit: 50
  )

  if matches.empty?
    # Tag exists locally but no build matches yet. Two possibilities:
    #   1. ASC is still indexing the just-uploaded build (~1-3 min lag)
    #   2. Upload failed silently and the user didn't notice
    # We can't distinguish without context, so show recent unrelated
    # builds (so the user sees "yes, ASC is reachable, just no match
    # for OUR tag") and advise a retry.
    puts Bootstrap::UI.warn("Tag #{latest_tag} (marketing version #{expected_version}) not yet visible in App Store Connect.")
    puts "  ASC indexes uploads asynchronously (~1-3 min after pilot returns)."
    puts
    recent = Spaceship::ConnectAPI::Build.all(
      app_id: app.id, sort: "-uploadedDate", limit: 5
    ).first(5) # Spaceship's `limit:` is per-page, not total — slice to enforce.
    unless recent.empty?
      puts Bootstrap::UI.dim("  Recent builds for #{config['BUNDLE_ID']} (for context — none match tag #{latest_tag}):")
      recent.each do |b|
        puts Bootstrap::UI.dim("    #{b.version} (#{b.app_version})  state=#{b.processing_state}  uploaded=#{b.uploaded_date}  platform=#{b.platform}")
      end
      puts
    end
    puts Bootstrap::UI.warn("Re-run `make verify` in 1-2 minutes. If still missing after 15 min, re-run `make ship`.")
    exit 2
  end

  pinpoint = expected_build ? " (looking for build #{expected_build})" : ""
  puts Bootstrap::UI.bold("Verifying tag #{latest_tag} (marketing version #{expected_version})#{pinpoint}:")
  matches.each do |b|
    state_marker = case b.processing_state
                   when "VALID"      then Bootstrap::UI.ok(b.version.to_s)
                   when "PROCESSING" then Bootstrap::UI.warn(b.version.to_s)
                   else                  Bootstrap::UI.miss(b.version.to_s)
                   end
    pinpoint_mark = (expected_build && b.version.to_s == expected_build.to_s) ? " ←" : ""
    puts "  #{state_marker} (#{b.app_version}) [#{b.platform}]  state=#{b.processing_state}  uploaded=#{b.uploaded_date}#{pinpoint_mark}"
  end

  states = matches.map(&:processing_state).uniq
  if states == ["VALID"]
    puts
    puts Bootstrap::UI.bold("✅ All #{matches.length} build#{matches.length == 1 ? '' : 's'} for #{latest_tag} are processed and ready for TestFlight testers.")
    exit 0
  elsif states.all? { |s| %w[VALID PROCESSING].include?(s) }
    pending = matches.count { |b| b.processing_state == "PROCESSING" }
    puts
    puts Bootstrap::UI.warn("⏳ #{pending}/#{matches.length} build#{matches.length == 1 ? '' : 's'} for #{latest_tag} still processing. Re-run in 5-10 min.")
    exit 2
  else
    bad = matches.reject { |b| %w[VALID PROCESSING].include?(b.processing_state) }
    puts
    puts Bootstrap::UI.miss("❌ #{bad.length}/#{matches.length} build#{matches.length == 1 ? '' : 's'} for #{latest_tag} in non-VALID state — check ASC for details.")
    exit 2
  end
end

# ─── Fallback: no local v* tag, report newest build by upload time ────────────
#
# Warn loudly because this can surface a build belonging to another
# shipper on the same bundle id (e.g. the canary).
puts Bootstrap::UI.warn("No local `v*` tag found — `make verify` falls back to reporting the newest TestFlight build,")
puts Bootstrap::UI.warn("which may belong to another shipper (e.g. the canary on a smoketest fork).")
puts Bootstrap::UI.warn("Run `make ship` (which pushes a v* tag) to enable precise verify targeting.")
puts

builds = Spaceship::ConnectAPI::Build.all(app_id: app.id, sort: "-uploadedDate", limit: 5).first(5) # Spaceship's `limit:` is per-page, not total — slice to enforce.
if builds.empty?
  puts Bootstrap::UI.miss("No TestFlight builds found for #{config['BUNDLE_ID']} (id=#{app.id})")
  puts "  Try `make ship` first; ASC ingestion takes 5-15 min after upload."
  exit 2
end

puts Bootstrap::UI.bold("Latest #{builds.length} builds for #{config['BUNDLE_ID']}:")
builds.each do |b|
  v = "#{b.version} (#{b.app_version})"
  state = b.processing_state
  uploaded = b.uploaded_date
  puts "  #{Bootstrap::UI.ok v}  state=#{state}  uploaded=#{uploaded}"
end

newest = builds.first
case newest.processing_state
when "VALID"
  puts
  puts Bootstrap::UI.bold("✅ Latest build #{newest.version} is processed and ready for TestFlight testers.")
  exit 0
when "PROCESSING"
  puts
  puts Bootstrap::UI.warn("⏳ Latest build #{newest.version} is still processing. Re-run in 5-10 min.")
  exit 0
else
  puts
  puts Bootstrap::UI.miss("Latest build #{newest.version} state=#{newest.processing_state}; check ASC for details.")
  exit 2
end
