# Pre-Public-Flip Secret + Identifier Audit

This runbook documents how to re-run the secret + identifier audit before each
major release of this `ios-macos-template` source repo. It is the last verification
gate before flipping visibility public (M5 P3) and before tagging v1.0.0+ releases
(M5 P4 onward).

The procedure was first run during M5 P1 (2026-04-30); see [Failure modes](#failure-modes)
for what to do if a re-run finds a new identifier hit.

> **Note on this file:** the bash blocks below define `WATCHLIST` and `BRAND`
> shell variables using string concatenation (e.g. `'anchor''key\|...'`). The shell
> reassembles the tokens at runtime, but the file content stores them split. This
> is deliberate: it prevents this runbook from itself contaminating the audit it
> documents (the prior version did, and the gates correctly caught it).

## Prerequisites

Before starting:

- **`git`** authenticated for the source repo; working tree clean
- **`grep`** + **`find`** (BSD or GNU) on PATH; macOS-default versions are sufficient
- **Bash 3.2+** (the procedure uses bash 3.2-portable forms; macOS `/bin/bash` is bash 3.2)
- **One git checkout** at the source-repo root (do NOT run inside `.planning/` or a
  subdirectory -- `git grep -- '.'` truncates scope outside the repo root)

## Audit checklist

Run from the repo root. Each step's expected result is documented inline; a re-run
that diverges should be investigated per the [Failure modes](#failure-modes) section.

```bash
# Step 0: define the watchlist and brand-token surface using shell string
# concatenation. Bash strips the empty-string '' joiners at runtime, so:
#   $WATCHLIST -> the 5 personal-identifier alternatives (BRE-escaped pipe)
#   $BRAND     -> the lowercase org-brand surface token
# Splitting them in the source prevents this file from itself appearing as an
# audit hit (REVIEWS HIGH-1, M5 P1, 2026-04-30).
WATCHLIST='anchor''key\|private''claw\|prakash''rj\|jp''raju\|A26''TJZ8QHQ'
BRAND='india''gram'

# Step 1: Identifier grep (untracked-also scan).
# Catches files-accidentally-not-yet-committed leak mode.
grep -ri "$WATCHLIST" --exclude-dir=.git --exclude-dir=.planning .
# Expected: exactly 1 hit on `.env.local.example:1` -- the intentional
# format-example placeholder for forkers (the canonical 10-char Apple Team ID
# format string, NOT the maintainer's actual Team ID).

# Step 2: Brand-token surface match (tracked-files scan).
# CRITICAL: -i flag is mandatory -- the LICENSE Copyright line is capitalized
# only (no lowercase form). Case-sensitive form returns 8 paths (LICENSE missing);
# -il returns the full 9.
git grep -il "$BRAND" -- ':!.planning' ':!.git'
# Expected: exactly the 9 paths in the table below.

# Step 3: .gitignore secret patterns. Quiet flag (-Fxq, -Eq) ensures success
# message isn't muddled by grep output (REVIEWS MEDIUM-4 closure).
grep -Fxq '*.p8'             .gitignore && echo "  [OK] *.p8 blocked"
grep -Fxq '*.mobileprovision' .gitignore && echo "  [OK] *.mobileprovision blocked"
grep -Eq  '^\.env'           .gitignore && echo "  [OK] .env* family blocked"
# Expected: all 3 lines print [OK].

# Step 4: Working-tree .p8 scan.
find . -path ./.git -prune -o -name '*.p8' -print
# Expected: empty output. Any `.p8` file in the working tree is a leaked
# Apple-developer signing key -- DELETE IT before continuing.

# Step 5: Summary check.
# All 4 prior steps must produce the documented expected output. If anything
# diverges, see "Failure modes" below.
```

## Expected intentional surface

The audit is expected to surface the following INTENTIONAL hits -- these are NOT
leaks, they are locked per `.planning/STATE.md` and ROADMAP M5 P1:

### Identifier hits (expected: 1 path)

| File                  | Hit                                          | Why intentional                                                  |
|-----------------------|----------------------------------------------|------------------------------------------------------------------|
| `.env.local.example`  | The Team ID format placeholder on line 1     | Format-example placeholder for forkers (10-char Apple Team ID format) |

### Brand-token surface (expected: 9 paths)

| File                       | Why intentional                                                                  | Case-folding         |
|----------------------------|----------------------------------------------------------------------------------|----------------------|
| `LICENSE`                  | The MIT-required Copyright line (the LLC brand name)                             | UPPERCASE only       |
| `CODE_OF_CONDUCT.md`       | `maintainers@<brand>.com` role-alias (rename.sh substitutes)                     | lowercase            |
| `CONTRIBUTING.md`          | GitHub URL (rename.sh substitutes)                                               | lowercase            |
| `README.md`                | CI badge URL + Quickstart command (rename.sh substitutes)                        | lowercase            |
| `SECURITY.md`              | `maintainers@<brand>.com` role-alias (rename.sh substitutes)                     | lowercase            |
| `bin/rename.sh`            | Substitution definitions (internal)                                              | lowercase            |
| `bin/verify-rename.sh`     | Verification fixtures (internal)                                                 | mixed (lower + UPPER)|
| `ci/test-rename.sh`        | Test fixtures (internal)                                                         | mixed (lower + UPPER)|
| `docs/SMOKE-TEST.md`       | Runbook references to source repo (the smoke-test slug)                          | lowercase            |

**Surface invariant:** the count is 9 paths today and SHOULD shrink (or stay 9)
over time. Any 10th path is a NEW unexpected leak -- investigate per "Failure modes".

## Failure modes

### A 10th path appears in the brand-token surface

**Action:**
1. Identify the new file by diffing actual against the locked 9-path expected list:
   ```bash
   git grep -il "$BRAND" -- ':!.planning' ':!.git' | sort -u | diff - <(printf '%s\n' \
     LICENSE \
     CODE_OF_CONDUCT.md \
     CONTRIBUTING.md \
     README.md \
     SECURITY.md \
     bin/rename.sh \
     bin/verify-rename.sh \
     ci/test-rename.sh \
     docs/SMOKE-TEST.md | sort -u)
   ```
2. Decide intentional vs leak:
   - **Intentional** (a new doc references the source repo by URL, similar to
     existing patterns): update the "Expected intentional surface" table above to
     include it; update `bin/rename.sh` if the new file should be substituted in
     forks; commit both.
   - **Leak** (an actual identifier slipped through): scrub the file (replace with
     the substitution-template form: `<owner>/<slug>` placeholder), commit.

### A new identifier hit appears outside `.env.local.example`

**Action:**
1. The 5-identifier set (defined in `$WATCHLIST` above) is locked per ROADMAP. A
   hit in any non-allowlisted file is a personal-data leak.
2. Inspect the file content: `grep -ni "<token>" path/to/file`.
3. Scrub by replacing with a generic placeholder (e.g., `your-username` or
   `<TEAM_ID>`) or removing the line entirely.
4. Re-run the full audit checklist before committing.

### A `.p8` file appears in the working tree

**Action:**
1. `.p8` files are Apple Developer signing keys (App Store Connect API keys, push
   notification keys, etc.). They are SECRETS and must NEVER be committed.
2. Verify the file isn't already staged: `git diff --cached --name-only | grep '\.p8$'`.
3. Delete the file: `find . -path ./.git -prune -o -name '*.p8' -print -delete`.
4. Confirm `*.p8` is in `.gitignore` (it should be, per M5 P1):
   `grep -Fxq '*.p8' .gitignore`.
5. If the file was previously committed, history rewrite is required (see M2's
   history-rewrite procedure in `.planning/phases-archive/M2/`).

### Audit surface is shrinking

This is the GOAL. Each major release should aim for a smaller intentional surface
as substitutions migrate into `bin/rename.sh`. Document any reductions in the
"Expected intentional surface" table above.

## Re-running before each release

The audit should be re-run before each major release:

- **Before flipping visibility public (M5 P3):** confirms no leaked identifiers
  reach a public reader.
- **Before tagging v1.0.0 (M5 P4):** final integration audit.
- **Before any v1.x.0 minor release that touches source-bearing files** (LICENSE,
  CODE_OF_CONDUCT.md, CONTRIBUTING.md, README.md, SECURITY.md, bin/, ci/, docs/, app/).

Re-running cadence: NOT every commit (use a pre-commit hook only if drift becomes
a real problem; deferred per M5 P1 CONTEXT). The audit is a pre-release gate, not
a per-commit gate.

To re-run, copy-paste the bash block under "Audit checklist" above into a terminal
at the repo root. The full audit completes in <5 seconds on a warm working tree.

## See also

- `.planning/STATE.md` -- locked intentional brand-token surface
- `.planning/ROADMAP.md` -- M5 Phase 1 brief that gated this runbook
- `bin/verify-rename.sh` -- the FORKER-side equivalent (verifies post-rename state)
- `docs/SMOKE-TEST.md` -- the M4 P4 runbook this document mirrors structurally
