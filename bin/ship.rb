#!/usr/bin/env ruby
# frozen_string_literal: true

# Trigger release.yml via workflow_dispatch on the configured app repo, then
# poll until the run completes. Prints the run URL up front so you can also
# watch in browser.
#
# Usage: bundle exec ruby bin/ship.rb [--dry-run]
#   --dry-run    pass dry_run=true (build + sign + export, skip TestFlight upload)
#
# Exit codes:
#   0 release succeeded (TestFlight upload + tag pushed)
#   1 invocation / I/O error
#   2 the workflow run completed with conclusion != success

require_relative "lib/bootstrap"

config = Bootstrap::Config.load!
config.validate!

dry_run = ARGV.include?("--dry-run") ? "true" : "false"
repo = config.repo_slug

puts Bootstrap::UI.bold("Triggering release.yml on #{repo} (dry_run=#{dry_run})…")
out, ok = Bootstrap::Sh.run("gh", "workflow", "run", "release.yml", "--ref", "main",
                            "-f", "dry_run=#{dry_run}", "--repo", repo)
unless ok
  Bootstrap::UI.fail!("gh workflow run failed:\n#{out}")
end

# gh doesn't print the run id immediately; poll the runs list briefly.
sleep 5
run_id = nil
20.times do
  out, _ = Bootstrap::Sh.run("gh", "run", "list", "--workflow", "release.yml",
                             "--repo", repo, "--limit", "1",
                             "--json", "databaseId,status,createdAt", "--jq", ".[0].databaseId")
  run_id = out.strip
  break unless run_id.empty?
  sleep 2
end
Bootstrap::UI.fail!("could not find newly-triggered run id") if run_id.to_s.empty?

run_url = "https://github.com/#{repo}/actions/runs/#{run_id}"
puts "  → #{run_url}"
puts

# Poll until completed
loop do
  out, _ = Bootstrap::Sh.run("gh", "run", "view", run_id, "--repo", repo,
                             "--json", "status,conclusion", "--jq", '"\(.status) \(.conclusion // "-")"')
  status, conclusion = out.strip.split(" ", 2)
  ts = Time.now.strftime("%H:%M:%S")
  puts "[#{ts}] #{status} #{conclusion}"
  if status == "completed"
    if conclusion == "success"
      puts
      puts Bootstrap::UI.bold("✅ Release succeeded.")
      puts "Tag pushed; both binaries uploaded to App Store Connect."
      puts "Run `make verify` to confirm TestFlight ingestion (~5-15 min ASC processing time)."
      exit 0
    else
      Bootstrap::UI.fail!("Release run #{run_id} concluded with: #{conclusion}\nSee #{run_url}")
    end
  end
  sleep 30
end
