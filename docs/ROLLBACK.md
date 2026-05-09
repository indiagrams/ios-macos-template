# Rollback / Undo

What to do if a `make ship` lands a build you didn't mean to ship, or if `make bootstrap-fork` fails partway through.

## Roll back a TestFlight build

TestFlight builds can't be deleted, but you can mark them expired (invisible to testers) and replace them. Two paths:

### Via App Store Connect web UI (fastest)

1. https://appstoreconnect.apple.com → My Apps → your app
2. TestFlight tab → iOS or macOS sidebar → Builds
3. Click the build you want to retire → "Expire" button (top-right) → confirm
4. Push a fresh build via `make ship` (CalVer auto-bumps to a new version)

### Via fastlane

```bash
bundle exec fastlane run testflight_expire build_number:<N>
```

Where `<N>` is the integer build number visible in ASC (e.g. `21`, not the full `v2026.19.21` tag).

## Roll back a git tag

If you pushed a tag and need to invalidate it (e.g. you noticed a secret leak post-push):

```bash
# Remove the tag locally + on origin
git tag -d v2026.19.X
git push --delete origin v2026.19.X
```

The tag's TestFlight build is still in ASC — handle that separately via the steps above.

## Roll back a partial bootstrap-fork

If `make bootstrap-fork` fails on step N (CI mode runs 18, local mode runs 14 — `make doctor` prints the live count), the pipeline is **idempotent** — re-running picks up where it left off:

```bash
make doctor          # see which step is the next pending one
make bootstrap-fork  # resumes from that step
```

If a specific step keeps failing and you want to skip it (rare; usually means upstream Apple/GH state is wrong):

1. Read the step's `check` and `do_it` methods in `bin/lib/bootstrap.rb`
2. Either fix the upstream state manually (e.g. delete the conflicting bundle ID in Apple Developer portal, then re-run), or
3. If the step is genuinely optional for your fork, delete it from the `PIPELINE` constant in `bin/lib/bootstrap.rb`. Don't skip it silently — leave a comment explaining why.

## Reset a fork to a clean slate

If you want to nuke a fork's Apple-side state and start over (e.g. you used the wrong bundle ID and want to free it up):

```bash
# 1. Delete the ASC App record (web UI; ASC API forbids DELETE)
#    https://appstoreconnect.apple.com → your app → App Information → Delete

# 2. Free the bundle ID
#    https://developer.apple.com/account/resources/identifiers/list
#    Click bundle ID → bottom of page → Delete

# 3. Optionally: clear the certs repo
git -C path/to/your-certs-repo log  # see what's in it
# fastlane match nuke distribution --readonly false   # nukes distro certs
# fastlane match nuke development --readonly false    # nukes dev certs

# 4. Re-run from a clean state
make bootstrap-fork
```

**Caution:** `match nuke` revokes certificates Apple-side. If your other apps share this team, they'll need to re-mint. Only do this if you're sure no other app depends on these certs.

## Reset the smoketest fork (maintainer-only)

Two canaries run on the smoketest, with different rollback semantics:

- **CI canary** (`canary-trigger.yml` dispatches `release.yml` on Mondays
  09:00 UTC) — uses persistent shipping certs from the certs repo. If the
  smoketest's signing state needs a reset, run `bin/refork-smoketest.sh`
  (destructive E2E that recreates the smoketest fork from scratch).
- **Local-mode canary** (`canary-local-mode.yml` on Saturdays 11:30 UTC) —
  self-rolls back per run via the `if: always()` post-step that revokes the
  3 just-minted certs. Orphan ids from a runner crash mid-mint are tracked
  via `actions/cache@v5` and cleaned up by the next run's pre-step (worst
  case: 1 week stale). If the cache is also lost (>7 days idle), revoke
  manually at <https://developer.apple.com/account/resources/certificates>
  (~30 sec). The canary's workflow header has the full failure-mode matrix.

## See also

- [`docs/CONTINUOUS-VALIDATION.md`](CONTINUOUS-VALIDATION.md) — the catalog of Apple-side gotchas the canary has surfaced
- [`docs/BOOTSTRAP.md`](BOOTSTRAP.md) — full `.bootstrap.env` reference
- [`bin/lib/bootstrap.rb`](../bin/lib/bootstrap.rb) — the 19-step pipeline source
