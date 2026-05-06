#!/usr/bin/env ruby
# frozen_string_literal: true

# Idempotent driver for forking the template. Reads `.bootstrap.env`, runs
# every programmatic step (rename, push, branch protection, GH secrets,
# certs repo, match, installer cert, optional icon swap). Halts on first
# blocker (typically: ASC App record not yet created — Apple disallows POST).
#
# Each step is no-op if its desired state is already reached, so re-running
# after a partial failure picks up where you left off.
#
# Usage: bundle exec ruby bin/bootstrap-fork.rb

require_relative "lib/bootstrap"

config = Bootstrap::Config.load!
Bootstrap::Runner.new(config).bootstrap
