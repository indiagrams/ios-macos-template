#!/usr/bin/env ruby
# frozen_string_literal: true

# Trigger release.yml on the configured app repo, then poll until completion.
# Idempotent:
#
#   - If a release run is already in progress on origin/main, tail it
#     instead of starting a new one. Pass --force to override.
#   - If origin/main's HEAD SHA already has a release tag pointing at it,
#     exit 0 ("already shipped") without triggering. Pass --force to override.
#
# Usage: bundle exec ruby bin/ship.rb [--dry-run] [--force]
#   --dry-run    pass dry_run=true (build + sign + export, skip TestFlight upload)
#   --force      ignore in-progress + already-shipped checks; trigger anyway
#
# Exit codes:
#   0 release succeeded (or was already shipped, or in-progress run completed)
#   1 invocation / I/O error
#   2 the workflow run completed with conclusion != success

require "json"
require_relative "lib/bootstrap"

config  = Bootstrap::Config.load!
config.validate!

dry_run = ARGV.include?("--dry-run") ? "true" : "false"
force   = ARGV.include?("--force")
repo    = config.repo_slug

def find_in_progress_run(repo)
  out, _ = Bootstrap::Sh.run("gh", "run", "list", "--workflow", "release.yml",
                              "--repo", repo, "--branch", "main", "--limit", "5",
                              "--json", "databaseId,status",
                              "--jq", '.[] | select(.status == "in_progress" or .status == "queued" or .status == "pending") | .databaseId')
  id = out.lines.first&.strip
  id && !id.empty? ? id : nil
end

def head_already_tagged?(repo)
  head_sha, ok = Bootstrap::Sh.run("gh", "api", "repos/#{repo}/commits/main", "--jq", ".sha")
  return nil unless ok
  head_sha = head_sha.strip
  return nil if head_sha.empty?
  tags_json, ok2 = Bootstrap::Sh.run("gh", "api", "repos/#{repo}/tags?per_page=20",
                                      "--jq", '[.[] | {name, sha: .commit.sha}]')
  return nil unless ok2 && !tags_json.strip.empty?
  match = JSON.parse(tags_json).find { |t| t["sha"] == head_sha }
  match ? [match["name"], head_sha] : nil
end

def trigger_new_run(repo, dry_run)
  puts Bootstrap::UI.bold("Triggering release.yml on #{repo} (dry_run=#{dry_run})…")
  out, ok = Bootstrap::Sh.run("gh", "workflow", "run", "release.yml", "--ref", "main",
                              "-f", "dry_run=#{dry_run}", "--repo", repo)
  Bootstrap::UI.fail!("gh workflow run failed:\n#{out}") unless ok

  # Poll for the new run to register
  sleep 5
  20.times do
    out, _ = Bootstrap::Sh.run("gh", "run", "list", "--workflow", "release.yml",
                                "--repo", repo, "--limit", "1",
                                "--json", "databaseId,status,createdAt",
                                "--jq", ".[0].databaseId")
    id = out.strip
    return id unless id.empty?
    sleep 2
  end
  Bootstrap::UI.fail!("could not find newly-triggered run id")
end

# ─── Resolve target run id ────────────────────────────────────────────────────
run_id = nil

unless force
  if (existing = find_in_progress_run(repo))
    puts Bootstrap::UI.warn("Existing release run already in progress on #{repo}/main: ##{existing}")
    puts "  → https://github.com/#{repo}/actions/runs/#{existing}"
    puts "  Tailing this run instead of starting a new one. Pass --force to override."
    puts
    run_id = existing
  elsif (already = head_already_tagged?(repo))
    tag, sha = already
    puts Bootstrap::UI.ok("HEAD on #{repo}/main is already shipped as tag #{tag}")
    puts Bootstrap::UI.dim("(SHA #{sha[0, 8]}; pass --force to ship again)")
    exit 0
  end
end

run_id ||= trigger_new_run(repo, dry_run)
run_url = "https://github.com/#{repo}/actions/runs/#{run_id}"
puts "  → #{run_url}"
puts

# ─── Poll until completed ─────────────────────────────────────────────────────
last_status = nil
loop do
  out, _ = Bootstrap::Sh.run("gh", "run", "view", run_id, "--repo", repo,
                              "--json", "status,conclusion",
                              "--jq", '"\(.status) \(.conclusion // "-")"')
  parts = out.strip.split(" ", 2)
  status, conclusion = parts[0], parts[1]
  if status != last_status
    ts = Time.now.strftime("%H:%M:%S")
    puts "[#{ts}] #{status} #{conclusion}"
    last_status = status
  end
  if status == "completed"
    if conclusion == "success"
      puts
      puts Bootstrap::UI.bold("✅ Release succeeded.")
      puts "Tag pushed; both binaries uploaded to App Store Connect."
      puts "Run #{Bootstrap::UI.bold 'make verify'} to confirm TestFlight ingestion (~5-15 min ASC processing time)."
      exit 0
    else
      puts
      Bootstrap::UI.fail!("Release run #{run_id} concluded with: #{conclusion}\nSee #{run_url}")
    end
  end
  sleep 30
end
