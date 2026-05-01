# Apple Account Prerequisites

What you need from Apple to use this template, broken down by what you actually plan to do.

## Three tiers of Apple account

### 1. Apple ID (free, required to download Xcode)

- Sign up: <https://appleid.apple.com>
- Used to download Xcode from the Mac App Store and to sign into Xcode for personal-team development signing.

### 2. Free Apple Developer account (free, optional)

- Sign in to Xcode (Xcode → Settings → Accounts → "+" → Apple ID) with your Apple ID and Xcode automatically enrolls you in the free developer tier.
- Lets you sideload your app to your own physical iPhone/iPad for testing.
- Provisioning profiles expire every 7 days (you re-build to refresh).
- No paid subscription required.

### 3. Apple Developer Program ($99 USD/year, required to ship)

- Enroll: <https://developer.apple.com/programs/>
- Required for:
  - App Store distribution
  - TestFlight builds
  - Push notifications, iCloud, Sign in with Apple, certain entitlements
  - Long-lived (1-year) provisioning profiles
- Individual or Organization tier — Organization needs a D-U-N-S number (free; takes a few business days).

## What this template specifically needs

| Capability | Apple ID | Free dev | Paid program |
|------------|----------|----------|--------------|
| Open the project in Xcode | ✓ | — | — |
| Build for iOS Simulator | ✓ | — | — |
| Build for macOS | ✓ | — | — |
| Run on a physical iPhone | — | ✓ | — |
| Submit to TestFlight | — | — | ✓ |
| Submit to App Store | — | — | ✓ |
| Use the fastlane release pipeline (`fastlane release`) | — | — | ✓ |
| Push notifications, iCloud, etc. | — | — | ✓ |

If you're just exploring the template, an Apple ID + free developer signing is enough. The paid program is only needed when you're ready to publish.

## Apple-side setup checklist (when ready to ship)

Once you've enrolled in the Apple Developer Program:

- [ ] Note your **Team ID** — visible at <https://developer.apple.com/account/> under Membership Details. 10-character alphanumeric string like `ABCDE12345`. Substitute it for `TEAM_ID_PLACEHOLDER` in `app/project.yml`.
- [ ] Create the app record on App Store Connect — <https://appstoreconnect.apple.com> → My Apps → "+". Use the bundle ID you set via `bin/rename.sh`.
- [ ] Generate an **App Store Connect API key** (recommended for fastlane non-interactive uploads):
  - <https://appstoreconnect.apple.com/access/integrations/api> → Team Keys → "+"
  - Role: App Manager (or higher)
  - Download the `.p8` private key — **download is one-time only**, save it carefully.
  - Note the **Key ID** and **Issuer ID** shown alongside.
- [ ] Place the `.p8` file **outside the repo** (e.g., `~/.appstoreconnect/`). The template's `.gitignore` blocks `*.p8`, but accidents happen.
- [ ] Configure fastlane to read the API key from your local secrets path. See `fastlane/Fastfile` for the expected env vars.

## Code-signing artifacts — DO NOT commit

The `.gitignore` already blocks the common ones, but be aware:

| File | Why it matters | Where to keep it |
|------|---------------|------------------|
| `*.p8` | App Store Connect API private key | `~/.appstoreconnect/` |
| `*.mobileprovision` | Provisioning profiles (manual signing) | `~/Library/MobileDevice/Provisioning Profiles/` (Xcode manages) |
| `*.cer`, `*.p12` | Distribution certificates | macOS Keychain |
| `.env.local` | Local secrets (API keys, paths) | repo root, gitignored |

If you accidentally commit any of these, treat it as a credential leak: revoke the key/cert immediately on Apple's side, then `git rm --cached` + force-rotate.

## Common gotchas

- **Free tier won't notarize.** macOS apps distributed outside the App Store need notarization, which requires the paid program.
- **Team membership ≠ ownership.** If you're added to someone else's Apple Developer team as a member, you can sign builds but may not have App Store Connect access. Coordinate with your team's Account Holder.
- **D-U-N-S number lookup is free.** If Apple says you need to "obtain" one for an Organization enrollment, use the free Apple lookup tool — don't pay D&B for one.
- **Apple ID without 2FA can't be added to a developer team** (Apple requirement). Enable 2FA before enrollment.

## Reference

- Apple Developer Program enrollment FAQ: <https://developer.apple.com/support/enrollment/>
- App Store Connect API: <https://developer.apple.com/documentation/appstoreconnectapi>
- fastlane App Store Connect API docs: <https://docs.fastlane.tools/app-store-connect-api/>
