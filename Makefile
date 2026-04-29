# Developer entry points for the iOS + macOS template.
#
# Run `make bootstrap` once after cloning. After that, `git push` runs
# ci/local-check.sh --fast automatically via lefthook.
#
# The stub app is named "HelloApp" with bundle id "com.example.helloapp".
# Rename for your project: see README.md → "Renaming the stub".

.PHONY: bootstrap check check-ios check-macos check-sim build generate icons screenshots release-dryrun setup-github phase-checklist milestone-checklist help

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

phase-checklist:
	@if [ -z "$(N)" ]; then echo "usage: make phase-checklist N=<phase>  (e.g. N=3.1)"; exit 2; fi
	@bin/phase-runbook.sh $(N)

milestone-checklist:
	@if [ -z "$(M)" ]; then echo "usage: make milestone-checklist M=<milestone>  (e.g. M=1)"; exit 2; fi
	@bin/phase-runbook.sh --milestone $(M)
