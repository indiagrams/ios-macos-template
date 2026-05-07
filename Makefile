# Developer entry points for the iOS + macOS template.
#
# Run `make bootstrap` once after cloning. After that, `git push` runs
# ci/local-check.sh --fast automatically via lefthook.
#
# The stub app is named "HelloApp" with bundle id "com.example.helloapp".
# Rename for your project: run `bin/rename.sh --help`.

.PHONY: all go bootstrap check check-ios check-macos check-sim build generate icons screenshots release-dryrun setup-github phase-checklist milestone-checklist help init doctor bootstrap-fork ship verify

help:
	@echo "Targets:"
	@echo "  bootstrap        One-time setup (brew bundle, lefthook install, xcodegen, bundle install)"
	@echo "  check            Same as: ci/local-check.sh --fast (iOS device build)"
	@echo "  check-ios        iOS device build (primary signal)"
	@echo "  check-sim        iOS Simulator build (backup signal)"
	@echo "  check-macos      macOS build"
	@echo "  generate         Regenerate HelloApp.xcodeproj from app/project.yml"
	@echo "  icons            Regenerate macOS AppIcon.iconset + AppIcon.icns from 1024 source"
	@echo "  screenshots      Capture App Store screenshots (iOS + macOS) to fastlane/screenshots/"
	@echo "  release-dryrun   fastlane release tag:v0.0.0 skip_upload:true skip_tag:true"
	@echo "  setup-github     Apply branch protection settings to current repo"
	@echo "  init             Scaffold .bootstrap.env from .bootstrap.env.example, auto-fill GH_ORG/GH_APP_REPO from origin remote"
	@echo "  all              One-shot: doctor → bootstrap-fork → ship → verify (the full forker journey)"
	@echo "  doctor           Read .bootstrap.env, validate Apple+GH credentials, print pipeline status"
	@echo "  bootstrap-fork   Idempotent: drive every programmatic fork-bootstrap step from .bootstrap.env"
	@echo "  ship             Trigger release.yml workflow_dispatch + tail until the run completes"
	@echo "  verify           Confirm the latest tagged build appeared in App Store Connect"
	@echo "  phase-checklist  Print the GSD canonical per-phase checklist (usage: make phase-checklist N=3.1)"
	@echo "  milestone-checklist  Print the GSD milestone wrap-up checklist (usage: make milestone-checklist M=1)"

bootstrap:
	brew bundle
	lefthook install
	cd app && xcodegen generate
	bundle install

check:
	ci/local-check.sh --fast

check-ios:
	ci/local-check.sh --fast

check-sim:
	ci/local-check.sh --owner-app-sim

check-macos:
	ci/local-check.sh --owner-app

generate:
	cd app && xcodegen generate

icons:
	swift ci/gen-macos-icons.swift \
	  app/macOS/Resources/AppIcon-source-1024.png \
	  app/macOS/Assets.xcassets/AppIcon.appiconset \
	  app/macOS/Resources/AppIcon.icns

screenshots:
	ci/take-screenshots.sh

release-dryrun:
	bundle exec fastlane release tag:v0.0.0 skip_upload:true skip_tag:true

setup-github:
	bin/setup-github.sh

init:
	@bin/init-bootstrap-env.sh

doctor:
	@bundle exec ruby bin/doctor.rb

bootstrap-fork:
	@bundle exec ruby bin/bootstrap-fork.rb

ship:
	@bundle exec ruby bin/ship.rb

verify:
	@bundle exec ruby bin/verify-testflight.rb

all: doctor bootstrap-fork ship verify
go: all

phase-checklist:
	@if [ -z "$(N)" ]; then echo "usage: make phase-checklist N=<phase>  (e.g. N=3.1)"; exit 2; fi
	@bin/phase-runbook.sh $(N)

milestone-checklist:
	@if [ -z "$(M)" ]; then echo "usage: make milestone-checklist M=<milestone>  (e.g. M=1)"; exit 2; fi
	@bin/phase-runbook.sh --milestone $(M)
