# Liquid Glass iOS 26 Polish Specification

Status: Complete v1
Purpose: Bring Maraithon Mobile in line with current iOS 26 SwiftUI and Liquid Glass guidance while preserving the production backend contract and the existing native architecture.
Audience: Product, design, and iOS engineering.

## 1. Overview and Goals

Maraithon Mobile is already a native SwiftUI Chief-of-Staff app with Magic sign-in, Today, Todos, People, and Chat. This pass upgrades the UI to feel current on iOS 26 without over-customizing the system. The goal is not to make everything glass; it is to make the app feel native, calm, and efficient on the 2026 Apple design system.

Apple's current guidance and local SDK audit lead to three product decisions:

| Decision | Rationale |
|---|---|
| Keep `TabView`, `NavigationStack`, `List`, `Form`, `.searchable`, sheets, toolbars, menus, and SF Symbols as the core UI. | Standard SwiftUI structures automatically adopt current Liquid Glass behavior and are easiest to keep accessible, adaptive, and App Store-safe. |
| Apply custom Liquid Glass sparingly to functional overlays and primary actions only. | Liquid Glass belongs in controls and navigation, not content cards. Overusing it in content creates visual hierarchy problems. |
| Use SDK-proven APIs only. | Xcode 26.4.1 exposes `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)`, `glassEffect(_:in:)`, `tabBarMinimizeBehavior(_:)`, `scrollEdgeEffectStyle(_:for:)`, and `backgroundExtensionEffect()`. |

## 2. Current-State Audit

### 2.1 Strengths

- The app targets iOS 26 and builds with Xcode 26.
- Top-level navigation uses native `TabView`.
- Each major workflow uses standard SwiftUI containers and native search.
- Sheets, menus, and toolbars are already system components.
- Production simulator verification against `maraithon.com` already covers Magic sign-in, todo mutation, and people mutation.
- Visual smoke tests already capture Today, Todos, People, Chat, and Chat Detail.

### 2.2 Gaps to Fix in This Pass

| Gap | Impact | Fix |
|---|---|---|
| `TabView` uses default minimization behavior. | On iPhone, the tab bar can occupy focus when users scroll dense task and people lists. | Opt in to `.tabBarMinimizeBehavior(.onScrollDown)`. |
| Glass APIs are used ad hoc nowhere. | Primary actions still look pre-iOS 26 in auth and chat surfaces. | Add shared design-system helpers for glass button/effect usage and use them consistently. |
| Chat composer is a custom bottom overlay but not clearly part of the iOS 26 functional layer. | Chat should feel like a first-class messaging pane similar to Telegram while matching system material behavior. | Apply an interactive glass effect to the composer controls and use glass buttons for prompt/send actions. |
| Magic sign-in primary actions are still bordered styles. | Authentication is the first impression and should show the current control family. | Convert primary auth actions to glass prominent, secondary development action to glass. |
| Verification captures only one appearance mode. | Liquid Glass and material legibility must be checked in light and dark. | Add a reusable visual smoke script that captures signed-in screenshots and supports appearance selection. |

## 3. Design Principles

- Native first: prefer standard SwiftUI app structures and controls over custom replicas.
- Content stays content: avoid Liquid Glass in ordinary content rows, cards, and metrics.
- Functional glass only: reserve glass for navigation, action controls, and transient overlays.
- Meaningful color: use tint to communicate state or primary action, not decoration.
- DRY implementation: centralize glass styling helpers in `Core/DesignSystem`.
- Test the real app: every polish pass must survive build, unit tests, visual screenshots, and production simulator verification.

## 4. Scope and Non-Goals

### 4.1 In Scope

- Add a shared Liquid Glass design-system helper.
- Opt the top-level tab bar into iPhone scroll minimization.
- Upgrade Magic sign-in buttons to current glass button styles.
- Upgrade Chat thread empty action and Chat Detail quick prompts/composer actions.
- Add a reusable signed-in visual smoke capture script for light/dark screenshots.
- Run XcodeGen, build, unit tests, visual smoke screenshots, production simulator verification, and final simulator launch.

### 4.2 Non-Goals

- No backend changes.
- No custom tab bar.
- No new third-party dependencies.
- No marketing landing pages or decorative backgrounds.
- No broad architecture migration.
- No use of custom glass effects in dense content lists unless a future spec proves a strong functional need.

## 5. Functional Requirements

### 5.1 iOS 26 App Structure

- The root app must continue to use native `TabView`.
- The tab bar must minimize on downward scrolling on iPhone.
- Screens must keep native `NavigationStack`, `.searchable`, sheets, menus, and toolbars so the system can apply Liquid Glass automatically.
- Existing tab labels remain user-centered: Today, Todos, People, Chat.

### 5.2 Design-System Glass Helpers

- New glass helpers must live in `Core/DesignSystem`.
- The helpers must expose:
  - standard glass button styling;
  - prominent glass button styling;
  - interactive glass capsule/circle effects for custom controls.
- Feature code must call these helpers instead of hardcoding glass styles repeatedly.
- Helpers must use only APIs confirmed in the local Xcode 26.4.1 SDK.

### 5.3 Magic Sign-In

- The main sign-in/sign-up CTA must use the prominent glass button style.
- The development magic-link action must use the standard glass button style.
- The pasted-link Continue action must use the prominent glass button style.
- Email/link text fields and informational containers remain standard content backgrounds, not Liquid Glass.

### 5.4 Chat

- The Chat empty-state New Chat CTA must use the prominent glass button style.
- Prompt chips must use the standard glass button style.
- The composer plus control and send control must feel like interactive iOS 26 controls without obscuring text entry.
- The composer stays anchored in the bottom safe-area inset and preserves Telegram-like quick-send behavior.
- Existing chat thread creation, prompt send behavior, and message persistence must remain unchanged.

### 5.5 Visual Verification

- A reusable script must:
  - source `Config/production-verification.env`;
  - generate a fresh production magic token for `kent@runner.now`;
  - run the existing visual smoke UI test;
  - write screenshots to a configurable output directory;
  - support `light` and `dark` simulator appearance.
- Screenshots must include Today, Todos, People, Chat, and Chat Detail.

## 6. Technical Design

| Component | Change |
|---|---|
| `Core/DesignSystem/LiquidGlassStyle.swift` | Add DRY view extensions for `.glass`, `.glassProminent`, and interactive glass shapes. |
| `Features/AppShell/AppShellView.swift` | Add `.tabBarMinimizeBehavior(.onScrollDown)`. |
| `Features/Auth/MagicSigninView.swift` | Replace bordered primary actions with shared glass helpers. |
| `Features/Chat/ChatThreadsView.swift` | Use shared prominent glass helper for the empty New Chat action. |
| `Features/Chat/ChatDetailView.swift` | Use shared glass helpers for prompt chips, plus action, and send action. |
| `scripts/capture-visual-smoke.sh` | Add reusable signed-in visual screenshot capture with appearance support. |
| `docs/spectacula` | Track this pass through in-progress and done manifests. |

## 7. Validation Matrix

| Gate | Required result |
|---|---|
| Source audit | Only official Apple docs/WWDC guidance and local Xcode SDK APIs drive iOS 26 decisions. |
| Spec lifecycle | Spec and manifest live under `docs/spectacula`; manifest moves to `done` only after verification. |
| XcodeGen | `xcodegen generate` passes. |
| Build | iOS Simulator build passes. |
| Unit tests | `MaraithonMobileTests` passes. |
| Visual smoke | Fresh light and dark screenshots are captured through the script. |
| Production simulator | `scripts/verify-production-simulator.sh` passes against `maraithon.com` for `kent@runner.now`. |
| Production assertions | Production todo create/complete and person create/update are confirmed. |
| Spec review | Implementation is compared against every in-scope requirement above. |

## 8. Assumptions

| Assumption | Impact |
|---|---|
| The app remains iOS 26-only in this repo. | No availability wrappers are required for iOS 26 APIs. |
| `maraithon.com` production auth remains compatible with the existing Fly magic-token generation path. | The new visual script can reuse the production verification config. |
| Current visual smoke UI coverage is enough for this polish pass. | No new XCTest flows are required unless implementation changes behavior. |
| Liquid Glass should improve hierarchy, not become decoration. | Content rows and metric surfaces stay stable unless they are actual controls. |

## 9. Definition of Done

- Every in-scope UI change is implemented through shared helpers or native SwiftUI APIs.
- The app builds and unit tests pass.
- Visual smoke screenshots are captured for light and dark appearance.
- Production simulator verification passes against `maraithon.com`.
- The verified app is launched in Simulator.
- The Spectacula manifest is moved to `done` with verification evidence.

## 10. Completion Notes

| Area | Result |
|---|---|
| Design system | Added `LiquidGlassStyle` helpers for standard glass buttons, prominent glass buttons, circular prominent glass controls, and interactive glass shapes. |
| App shell | Added `.tabBarMinimizeBehavior(.onScrollDown)` to the native `TabView`. |
| Auth | Updated Magic sign-in/sign-up primary CTAs and magic-link continuation to use shared glass styles. |
| Chat | Updated Chat empty-state CTA, visible prompt chips, plus control, and send control with iOS 26 glass styling while keeping the bottom composer behavior intact. |
| Visual smoke | Added `scripts/capture-visual-smoke.sh` and shared `scripts/lib/production-magic-token.sh`; made visual UI tests reset local state for deterministic screenshots. |
| Production verification | Refactored the production simulator script to reuse the shared token helper without changing the API contract. |

## 11. Verification

| Gate | Result |
|---|---|
| Apple/source audit | Completed with official Apple guidance and local Xcode 26.4.1 SDK API checks. |
| XcodeGen | Passed via `xcodegen generate`. |
| Shell syntax | Passed via `bash -n scripts/verify-production-simulator.sh scripts/capture-visual-smoke.sh scripts/lib/production-magic-token.sh`. |
| Manifest JSON | Passed via `jq empty docs/spectacula/done/liquid-glass-ios26-polish.json`. |
| Build | Passed via `xcodebuild ... build`. |
| Unit tests | Passed via `xcodebuild ... -only-testing:MaraithonMobileTests test`. |
| Visual smoke, light | Passed via `scripts/capture-visual-smoke.sh light build/verification/liquid-glass-light`; captured Today, Todos, People, Chat, and Chat Detail. |
| Visual smoke, dark | Passed via `scripts/capture-visual-smoke.sh dark build/verification/liquid-glass-dark`; captured Today, Todos, People, Chat, and Chat Detail. |
| Visual review | Passed after fixing an oversized Chat empty-state glass button and rerunning light/dark screenshots. |
| Production simulator | Passed via `scripts/verify-production-simulator.sh` for run `20260526031030`. |
| Production assertions | Passed: todo `iOS prod todo 20260526031030` created/completed; person `iOS Prod Person 20260526031030` created/updated. |
| Simulator launch | Passed via `xcrun simctl launch ... com.bliss.maraithonmobile` after production verification. |
