#!/usr/bin/env ruby
# frozen_string_literal: true

# Read-only validator for `.bootstrap.env`. Probes Apple + GitHub + local repo
# state, prints a checklist showing which steps are done vs pending vs blocked.
# Exit codes:
#   0  all steps done OR pending steps with no blockers (run `make bootstrap`)
#   1  argument / I/O failure
#   2  one or more blockers (need user action; see output)
#
# Side-effect free.
#
# Usage: bundle exec ruby bin/doctor.rb

require_relative "lib/bootstrap"

config = Bootstrap::Config.load!
Bootstrap::Runner.new(config).doctor
