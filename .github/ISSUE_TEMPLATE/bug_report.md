---
name: Bug report
about: Report a bug in the template scaffolding (build, CI, fastlane, scripts)
title: '[BUG] '
labels: [bug]
assignees: []
---

<!--
Thanks for taking the time to file a bug. The template only gets better
when sharp edges get reported. The sections below help us reproduce what
you hit; please fill in what you can — partial reports are fine, we'll
ask follow-ups in the thread.

PRINCIPLES.md #19: bug reports without reproduction steps don't get
closed — they get a gentle nudge back to the template. The form exists
to help you write a useful issue, not to gate participation.
-->

## What's broken

<!-- One or two sentences. What did you try to do, and what went wrong? -->

## Steps to reproduce

<!-- Numbered list, ideally a minimal repro. The smaller the example, the faster the fix. -->

1.
2.
3.

## Expected vs actual

<!-- What you expected to happen, and what actually happened. -->

**Expected:**

**Actual:**

## Environment

<!-- Fill in what applies. Template version = the commit SHA or tag you cloned from. -->

- macOS version:
- Xcode version (`xcodebuild -version`):
- Device / simulator (if relevant):
- Template version (commit SHA or tag):

## Logs / output

<!-- Paste the relevant output inside the fenced block below. `make check` failures, `xcodebuild` errors, fastlane traces, etc. Trim to the relevant lines if it's long. -->

```
<paste here>
```

## Anything you've already tried

<!-- Optional but useful — saves us from suggesting things you've already ruled out. -->

-

## Checklist before submitting

- [ ] I've searched existing issues for duplicates.
- [ ] I've read [CONTRIBUTING.md](../../CONTRIBUTING.md).
- [ ] I'm running `make check` locally and the failure reproduces.
