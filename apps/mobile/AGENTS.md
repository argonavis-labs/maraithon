# Agent Instructions

This repository is a native iOS 26 SwiftUI app. Treat these instructions as the working contract for any coding agent making changes here.

## Project Baseline

- App target: `MaraithonMobile`
- Test target: `MaraithonMobileTests`
- Project generation: `project.yml` with XcodeGen
- Minimum platform: iOS 26.0
- Swift version: Swift 6.3
- Primary stack: SwiftUI, SwiftData, Observation, Swift Testing
- Current feature areas: Auth, Todos, CRM, Chat

Use Apple frameworks first. Add third-party packages only when they remove meaningful complexity, are actively maintained, and are justified in the change summary.

## Required Workflow

1. Read the affected feature and shared Core files before editing.
2. Preserve the existing `Core/` and `Features/` ownership boundaries.
3. Prefer small pure helpers for business rules, filtering, formatting, validation, and deterministic behavior.
4. Keep SwiftUI views focused on rendering, local interaction state, and composition.
5. Regenerate the project after changing `project.yml` or adding/removing source files:

```sh
xcodegen generate
```

6. Current product-iteration mode: run the app build before finishing, but do not run Xcode tests or broad test suites unless Kent explicitly re-enables tests or asks for them.

```sh
xcodebuild -quiet -project MaraithonMobile.xcodeproj -scheme MaraithonMobile -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4.1' build
```

If a simulator is unavailable or busy, list available devices with `xcrun simctl list devices available` and use another iOS 26 simulator. Do not delete or weaken tests; this is only a temporary no-test execution mode for faster live iteration.

Production verification scripts that call Fly must source the shared deploy env from `~/.config/maraithon/fly-prod.env` or `MARAITHON_DEPLOY_ENV_FILE`, require `FLY_API_TOKEN`, and use `MARAITHON_FLY_APP` as the pinned Fly app. Do not depend on the active `flyctl` account.

## Architecture Rules

- `App/` owns app entry, root routing, and shared environment setup.
- `Core/Auth/` owns auth contracts, auth models, and session state.
- `Core/Models/` owns SwiftData model types and domain enums.
- `Core/Persistence/` owns model container creation, seed data, and reset behavior.
- `Core/DesignSystem/` owns reusable visual primitives that are used by multiple features.
- `Core/Utilities/` owns shared pure utilities such as formatting and validation.
- `Features/<Feature>/` owns feature screens, feature-only helpers, and feature-specific state.

Do not move feature-specific logic into `Core/` unless at least two features use it. Do not create generic abstractions just to reduce a few lines of readable code.

## SwiftUI Rules

- Use `App`, `Scene`, `View`, `TabView`, `NavigationStack`, `NavigationLink`, `.sheet`, `.toolbar`, `.searchable`, `.swipeActions`, `Menu`, `Form`, `List`, and `ContentUnavailableView` before custom navigation or presentation code.
- Keep one navigation stack per tab unless a feature explicitly needs shared cross-tab navigation.
- Use `@State` for view-local value state, `@Bindable` for editable observable/model state, `@Environment` for injected dependencies, and SwiftData `@Query` for view-owned fetches.
- Keep view bodies readable. Extract subviews when a body becomes hard to scan or repeats a real pattern.
- Prefer semantic text styles, SF Symbols, system colors, system materials, and native controls.
- Support Dynamic Type and dark mode by default. Avoid hard-coded heights for text-heavy UI.
- Add accessibility labels for icon-only buttons, destructive actions, and custom interactive elements.

## SwiftData Rules

- Store durable user/domain data in SwiftData `@Model` types.
- Keep model relationships explicit and use delete rules intentionally.
- Save after user-visible mutations. If save can fail in a user flow, surface a local error instead of silently losing state.
- Keep seed/reset behavior idempotent and relationship-safe.
- Do not add schema fields casually. If a schema change is needed, document the migration impact in the change summary.

## State, Concurrency, and Dependency Rules

- Use Observation (`@Observable`) for app-owned observable state.
- Keep services behind protocols when UI should not know about the implementation.
- Use `async`/`await` for asynchronous work.
- Keep UI-affecting state on the main actor.
- Do not store secrets, API keys, or production credentials in source.
- The local Magic Signin provider is a development implementation behind `AuthProviding`; production Magic integration must replace the provider, not the UI flow.

## DRY and Modularity Rules

- DRY means one source of truth for domain behavior, not one giant shared helper.
- Put reusable business logic in pure types like `TodoFiltering`, `CRMFiltering`, `ChatResponder`, and `ChatThreadNaming`.
- Keep reusable UI primitives small and specific. Avoid broad "BaseView", "BaseViewModel", or catch-all utility types.
- Prefer composition over inheritance.
- Prefer value types for pure data and helper logic.
- Name files after the primary type they contain.

## Testing Rules

- Current mode: do not run Xcode tests by default. Kent is testing live in production until he says to harden the app again.
- Add or update tests for every nontrivial domain rule, validator, formatter, filter, naming algorithm, auth behavior, and persistence helper.
- Keep pure helper tests independent of SwiftUI and simulator UI whenever possible.
- Use Swift Testing with `@Suite`, `@Test`, and `#expect`.
- Use isolated `UserDefaults` suites and in-memory containers when testing stateful services.
- Do not rely on seeded persistent data for unit tests unless the test is explicitly validating seeding.

## UI Quality Bar

- Build the actual app surface, not a marketing page.
- Operational screens should be dense, scannable, and calm.
- Use native iOS controls for common actions.
- Prefer menus, swipe actions, search, segmented controls, sheets, and confirmation dialogs over custom widgets.
- Avoid decorative gradients, excessive card nesting, custom icon systems, or nonstandard controls unless they solve a concrete problem.

## Verification Checklist

Before finishing a code change, report:

- Files changed at a high level.
- Whether `xcodegen generate` was needed and whether it passed.
- Build result.
- Test result, or that tests were intentionally not run under the current product-iteration mode.
- Any skipped verification and the reason.

Official Apple references used as the baseline for this guidance:
- SwiftUI: https://developer.apple.com/documentation/swiftui/
- SwiftUI navigation: https://developer.apple.com/documentation/SwiftUI/Bringing-robust-navigation-structure-to-your-swiftui-app
- SwiftUI state: https://developer.apple.com/documentation/swiftui/state
- Xcode testing and Swift Testing: https://developer.apple.com/documentation/xcode/testing
