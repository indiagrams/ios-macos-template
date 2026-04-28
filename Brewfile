# iOS + macOS template — dev tools. Install with `brew bundle`.
# Or run `make bootstrap` (also runs lefthook + xcodegen + bundle install).

# Build / project generation
brew "xcodegen"        # app/project.yml → HelloApp.xcodeproj
brew "swiftlint"       # Swift lint
brew "xcbeautify"      # nicer xcodebuild logs
brew "xcresultparser"  # parse .xcresult bundles in CI

# Git workflow
brew "lefthook"        # pre-push hook → ci/local-check.sh --fast
brew "gh"              # PR / release CLI

# Release pipeline
brew "fastlane"        # signs iOS + macOS, uploads to TestFlight + App Store metadata

# Optional: only needed if you generate macOS app icons via ci/gen-macos-icons.swift
# (the CILanczosScaleTransform-based script ships in this template).
# brew "imagemagick"    # uncomment if you do screenshot diffing
