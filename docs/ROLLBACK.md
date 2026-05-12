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

If `make bootstrap-fork` fails on step N (both CI mode and local mode run 16 steps post-v1.6 — `make doctor` prints the live count), the pipeline is **idempotent** — re-running picks up where it left off:

```bash
make doctor          # see which step is the next pending one
make bootstrap-fork  # resumes from that step
```

If a specific step keeps failing and you want to skip it (rare; usually means upstream Apple/GH state is wrong):

1. Read the step's `check` and `do_it` methods in `bin/lib/bootstrap.rb`
2. Either fix the upstream state manually (e.g. delete the conflicting bundle ID in Apple Developer portal, then re-run), or
3. If the step is genuinely optional for your fork, delete it from the `PIPELINE` constant in `bin/lib/bootstrap.rb`. Don't skip it silently — leave a comment explaining why.

## Roll back a failed release (mid-mint cert cleanup)

Since v1.6, `release.yml` mints fresh signing certs at the start of every run and revokes them in an `if: always()` post-step — there's no certs repo to roll back, and no manual cert cleanup after a normal failed release. The post-step runs whether the build succeeded, failed, or was cancelled.

If a runner crashes hard enough to skip the post-step (process killed, hosted runner evicted), the next `release.yml` run's pre-step revokes any orphan IDs tracked by the previous run via `actions/cache@v5`. Worst case: the orphan lingers until the next release.

Manual cleanup is only needed if **both** the post-step and the cache miss (e.g. >7 days idle and cache evicted). Symptom is a failed `make ship` whose log contains:

```
[!] Could not create another Distribution certificate, reached the maximum
    number of available Distribution certificates.
```

Two ways to recover:

**Automated (preferred):**

```bash
make revoke-orphan-certs DRY_RUN=1   # list orphans first
make revoke-orphan-certs             # interactive revoke
# or: make revoke-orphan-certs YES=1   (skip prompt)
```

Apple's distribution-cert list is diffed against your local `~/Library/Keychains/login.keychain-db`. Only certs whose private keys live nowhere on your Mac get revoked — certs you're actively using for local-mode signing are left alone by the safety guard. Re-run `make ship` after the orphans clear.

**Manual fallback** (if for some reason the automated path is unavailable):

1. https://developer.apple.com/account/resources/certificates/list
2. Filter type = Apple Distribution → revoke entries whose private keys aren't in your `~/Library/Keychains/login.keychain-db` (~30 sec; check each cert's name + creation date carefully — revoking an in-use cert breaks signing on the machine that holds its private key)
## Reset a fork to a clean slate

If you want to nuke a fork's Apple-side state and start over (e.g. you used the wrong bundle ID and want to free it up):

```bash
# 1. Delete the ASC App record (web UI; ASC API forbids DELETE)
#    https://appstoreconnect.apple.com → your app → App Information → Delete

# 2. Free the bundle ID
#    https://developer.apple.com/account/resources/identifiers/list
#    Click bundle ID → bottom of page → Delete

# 3. Re-run from a clean state
make bootstrap-fork
```

There's no certs repo to clear in v1.6 — every `release.yml` run mints its own short-lived certs and revokes them in the `if: always()` post-step, so there's no persistent signing state attached to the fork.

## Reset the smoketest fork (maintainer-only)

Two canaries run on the smoketest — `canary-trigger.yml` dispatching `release.yml` (Sundays 07:00 UTC) and `canary-local-mode.yml` (Saturdays 07:00 UTC). Since v1.6 both paths mint fresh certs per run and self-revoke via an `if: always()` post-step, so they're equivalent from a rollback standpoint.

To reset the smoketest:

```bash
bin/refork-smoketest.sh   # destructive E2E that recreates the smoketest fork
```

No manual cert cleanup is required — both canaries revoke their minted certs at the end of every run, and orphans from a runner crash are reaped by the next run's pre-step (cache-tracked, worst case 1 week stale). If both the post-step and cache miss, revoke manually at <https://developer.apple.com/account/resources/certificates> (~30 sec). The canary's workflow header has the full failure-mode matrix.

## See also

- [`docs/CONTINUOUS-VALIDATION.md`](CONTINUOUS-VALIDATION.md) — the catalog of Apple-side gotchas the canary has surfaced
- [`docs/BOOTSTRAP.md`](BOOTSTRAP.md) — full `.bootstrap.env` reference
- [`bin/lib/bootstrap.rb`](../bin/lib/bootstrap.rb) — the 17-step pipeline source (16 steps active per mode after mode-specific filtering)
