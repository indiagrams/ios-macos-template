#!/usr/bin/env ruby
# frozen_string_literal: true

# Confirm the latest tagged release built+uploaded by `make ship` actually
# made it into App Store Connect. Probes ASC for the most recent build
# attached to the configured Bundle ID; prints version + state. Exits 0 if
# any build exists for this app, else 2.
#
# Usage: bundle exec ruby bin/verify-testflight.rb

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

builds = Spaceship::ConnectAPI::Build.all(app_id: app.id, sort: "-uploadedDate", limit: 5)
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
