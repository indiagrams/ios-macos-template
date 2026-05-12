import Foundation

/// Stable identifiers for UI test queries.
///
/// **Why these exist.** UI tests should never match elements by their visible
/// text — the moment your app supports another language (or you tweak copy),
/// the test silently breaks. Use these constants in both your views and
/// your tests so the contract is explicit and refactor-safe.
///
/// **Adding an identifier.** Define a constant here, attach it to the view
/// via `.accessibilityIdentifier(AccessibilityIdentifiers.<name>)`, and
/// query it in tests via `app.staticTexts[AccessibilityIdentifiers.<name>]`
/// (or `.otherElements`, `.buttons`, `.images` etc. depending on the SwiftUI
/// element type backing it).
///
/// **Single source of truth.** This file is compiled into BOTH the main
/// app target (via `app/Shared/**`) AND the UI test target (via an
/// explicit `sources:` entry in project.yml / Project.swift). UI tests
/// run as a separate process and can't link the app binary, so the
/// standard `@testable import` pattern doesn't apply for them. Compiling
/// the one shared file into both targets preserves the single-source-of-
/// truth property — refactor here and both ends see it.
///
/// **Naming convention.** Dotted, lowercase, scoped by feature
/// (`HelloApp.title`, `Settings.signIn`, `Trends.chart`). The leading scope
/// makes them grep-friendly and avoids collisions as forks add features.
public enum AccessibilityIdentifiers {
    /// The "HelloApp" title text — stable selector for UI tests across locales.
    /// SwiftUI Text elements surface in XCUITest queries as `app.staticTexts[id]`.
    /// SwiftUI containers (VStack, HStack, ZStack) without an explicit
    /// accessibility role don't surface independently, so attach identifiers
    /// to elements that XCUITest can actually query.
    public static let title = "HelloApp.title"
}
