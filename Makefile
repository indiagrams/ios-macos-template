# Developer entry points for the iOS + macOS template.
#
# Forking your own app from this template? The path is:
#
#   1. gh repo create my-app --template indiagrams/apple-shipkit --public --clone
#   2. cd my-app && make bootstrap   # one-time dev-env setup (brew + ruby gems + xcodegen + git hooks)
#   3. make init                     # scaffolds .bootstrap.env (auto-fills GH_ORG/GH_APP_REPO from origin)
#   4. $EDITOR .bootstrap.env        # fill in APP_NAME, BUNDLE_ID, Apple credentials, RELEASE_MODE
#   5. make all                      # doctor → bootstrap-fork → ship → verify (the full forker journey)
#
# Maintaining this template? `make check` runs the local CI check, lefthook
# wires it onto every push, and `make doctor` validates `.bootstrap.env` end
# to end without mutating any state.

.PHONY: all go bootstrap check check-ios check-macos check-sim build generate icons screenshots release-dryrun setup-github phase-checklist milestone-checklist help init doctor bootstrap-fork ship verify submit mint-local-certs clean-revoked-certs format format-check _check-bundle

help:
	@echo "Targets:"
	@echo "  bootstrap        One-time dev-env setup after clone (brew bundle, lefthook install, xcodegen, bundle install). Distinct from bootstrap-fork."
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
	@echo "  bootstrap-fork   Idempotent fork-bootstrap: certs, ASC bundle id, GH branch protection, etc. Reads .bootstrap.env."
	@echo "  ship             Trigger release.yml workflow_dispatch + tail until the run completes"
	@echo "  verify           Confirm the latest tagged build appeared in App Store Connect"
	@echo "  submit           Stage (default) or auto-submit the latest TestFlight build for App Store review across PLATFORMS. Toggle via SUBMIT_FOR_REVIEW in .bootstrap.env."
	@echo "  mint-local-certs Auto-mint missing local-mode signing identities into the login keychain via fastlane cert. Idempotent."
	@echo "  clean-revoked-certs  Audit login.keychain vs Apple's valid-cert list, delete revoked locals (usage: make clean-revoked-certs [DRY_RUN=1] [YES=1])"
	@echo "  phase-checklist  Print the GSD canonical per-phase checklist (usage: make phase-checklist N=3.1)"
	@echo "  milestone-checklist  Print the GSD milestone wrap-up checklist (usage: make milestone-checklist M=1)"

bootstrap:
	brew bundle
	lefthook install
	cd app && xcodegen generate
	bundle install

format:
	swiftformat app/

format-check:
	swiftformat --lint app/

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

screenshots: _check-bundle
	ci/take-screenshots.sh

release-dryrun: _check-bundle
	bundle exec fastlane release tag:v0.0.0 skip_upload:true skip_tag:true

setup-github:
	bin/setup-github.sh

init:
	@bin/init-bootstrap-env.sh

doctor: _check-bundle
	@bundle exec ruby bin/doctor.rb

bootstrap-fork: _check-bundle
	@bundle exec ruby bin/bootstrap-fork.rb

ship: _check-bundle
	@bundle exec ruby bin/ship.rb

verify: _check-bundle
	@bundle exec ruby bin/verify-testflight.rb

submit: _check-bundle
	@bundle exec ruby bin/submit.rb

mint-local-certs: _check-bundle
	@bundle exec ruby bin/mint-local-certs.rb

clean-revoked-certs: _check-bundle
	@bundle exec ruby bin/clean-revoked-certs.rb $(if $(YES),--yes,) $(if $(DRY_RUN),--dry-run,)

# Guard for bundle-using targets above. Fails fast with an actionable hint
# when ruby gems aren't installed yet (typical on a fresh fork before
# `make bootstrap` has run). Without this guard, `make doctor` would crash
# with a Bundler::GemNotFound stack trace before the user has any chance to
# learn what went wrong.
_check-bundle:
	@bundle check >/dev/null 2>&1 || { \
	  printf "\nRuby gems aren't installed yet. Run one of:\n\n"; \
	  printf "    bundle install            # install just the ruby gems\n"; \
	  printf "    make bootstrap            # full dev-env setup (brew + lefthook + xcodegen + bundle)\n\n"; \
	  exit 1; \
	}

all: doctor bootstrap-fork ship verify
go: all

phase-checklist:
	@if [ -z "$(N)" ]; then echo "usage: make phase-checklist N=<phase>  (e.g. N=3.1)"; exit 2; fi
	@bin/phase-runbook.sh $(N)

milestone-checklist:
	@if [ -z "$(M)" ]; then echo "usage: make milestone-checklist M=<milestone>  (e.g. M=1)"; exit 2; fi
	@bin/phase-runbook.sh --milestone $(M)
