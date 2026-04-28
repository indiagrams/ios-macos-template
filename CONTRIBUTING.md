# Contributing to ios-macos-template

This is a small, opinionated template for iOS + macOS apps. We say yes to
fixes for the gotchas hiding in `xcodebuild`, `fastlane deliver`, `actool`,
and `codesign` — because someone hit them, debugged them, and shouldn't
have to do that again. We say no to features that fit a specific use case
but not the broader iOS/macOS world.

Before opening a PR, ask:

- Does this fix a sharp edge a stranger would hit?
- Does it preserve the "5-minute clone-to-first-build" promise?
- Does it generalize, or is it specific to your project?

If the answer to all three is yes, open a PR. If you're unsure, open an issue first.

## Quickstart

```bash
# 1. Fork on GitHub, then clone your fork
git clone https://github.com/<you>/ios-macos-template.git
cd ios-macos-template

# 2. One-time setup (brew bundle, lefthook install, xcodegen, bundle install)
make bootstrap

# 3. Create a topic branch
git checkout -b fix/short-description

# 4. Make your change

# 5. Verify locally — must be green before pushing
make check

# 6. Push (lefthook also runs ci/local-check.sh --fast as a pre-push hook)
git push -u origin fix/short-description

# 7. Open a PR against main
gh pr create
```

`make check` is the floor. If it's red locally, the PR won't merge — branch
protection enforces this for everyone, maintainers included
([PRINCIPLES.md](docs/PRINCIPLES.md) #4). The pre-push hook runs
`ci/local-check.sh --fast` automatically, which is the same iOS-device
build CI runs on every PR — so by the time you push, you've already passed
the primary signal.

## What every PR needs

1. **Three CI checks green.** Branch protection on `main` enforces this.
   The required jobs are:
   - `app (iOS device)`
   - `app (iOS Simulator)`
   - `app (macOS)`

   These names are pinned in `.github/workflows/pr.yml` and mirrored in
   `bin/setup-github.sh`. Renaming a job means updating both — see
   [PRINCIPLES.md](docs/PRINCIPLES.md) #10 (semver applies to template
   structure).

2. **A Test plan in the PR description.** Even one-line typo fixes. Even
   docs-only changes. The point is the muscle memory — you confirm to
   yourself that you actually verified the change before asking a reviewer
   to. For docs-only changes, "rendered the file on github.com — looks
   correct" is a valid Test plan.

3. **Squash-merge only, linear history.** No merge commits. No rebase
   merges. Repo settings enforce squash-merge. `git log` reads like a
   sequence of features, not a tangle
   ([PRINCIPLES.md](docs/PRINCIPLES.md) #3).

4. **CHANGELOG entry in the same PR as the change.** `CHANGELOG.md`
   doesn't exist yet — it lands with the v1.0.0 public release. Until
   then, the convention is git-log-driven; once the file exists, this
   rule applies per [PRINCIPLES.md](docs/PRINCIPLES.md) #9.

## Cross-repo coordination: `ci/lib/`

Files in `ci/lib/` (today: `ci/lib/resolve-dist-cert-sha.sh` and
`ci/lib/SHA256SUMS`) are SHA-pinned. They are byte-identical with the
same files in downstream consumer repos derived from this template.
`ci/local-check.sh`'s `verify_helpers_in_sync` step verifies the
`SHA256SUMS` match on every run; drift is a CI failure, not a warning
([PRINCIPLES.md](docs/PRINCIPLES.md) #5).

If your PR modifies anything under `ci/lib/`:

1. Call it out clearly in the PR description.
2. Regenerate the hashes:
   ```bash
   shasum -a 256 ci/lib/*.sh > ci/lib/SHA256SUMS
   ```
3. Expect the maintainer to coordinate the rollout — the same
   byte-identical change must land in every downstream consumer repo
   derived from this template in the same release cycle. This is why
   `ci/lib/` changes are slower than other PRs. It's not a bottleneck
   imposed for fun; it's the cost of keeping the shared helpers actually
   shared.

## Code of Conduct

By participating in this project, you agree to abide by our
[Code of Conduct](CODE_OF_CONDUCT.md). This project adopts the
Contributor Covenant 2.1 verbatim — no edits, no custom carve-outs
([PRINCIPLES.md](docs/PRINCIPLES.md) #18).

## Style notes

The full operating manual is [docs/PRINCIPLES.md](docs/PRINCIPLES.md)
(24 rules). The ones a contributor will hit on day one:

- **Every script has a "why" header comment** (rule 6) — explain the
  constraint, the incident, or the gotcha that justified writing the
  script. The *what* is in the code; the *why* belongs at the top.
- **README answers what / why / how in the first 50 lines** (rule 7) —
  beyond that is reference material. A reader should know if this
  template is for them without scrolling.
- **Non-obvious patterns get a "Why this exists" section** (rule 8) —
  both in source comments AND in the README. If you remove the pattern,
  you remove its explanation too.
- **No secrets in any committed file, ever** (rule 13). `.env*`, `*.p8`,
  `*.pem`, and `*.mobileprovision` are gitignored. If you're adding a
  new secret-shaped file, add the pattern to `.gitignore` in the same
  PR.

## Discussing before opening a PR

For larger changes — anything touching `ci/lib/`, the release pipeline,
the renaming script (when it lands), or the public template "API"
(directory layout, script names, Makefile targets) — open a [GitHub
issue](https://github.com/indiagrams/ios-macos-template/issues) first.
We'll discuss the shape before you spend time on the implementation.

(Issue templates are coming in a near-term update; for now, free-form is fine.)

## Response time

Issues and PRs get a first response within ~7 days
([PRINCIPLES.md](docs/PRINCIPLES.md) #23). That might be "looking at
it", "let's iterate on the approach", or "this isn't the right fit,
here's why" — acknowledgement, not resolution. We don't promise
resolution timelines; we do promise we won't ghost you.
