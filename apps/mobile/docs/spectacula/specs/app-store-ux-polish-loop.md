# App Store UX Polish Loop Specification

Status: Complete v1
Purpose: Audit and upgrade the native SwiftUI mobile app into a tighter App Store-ready Chief-of-Staff experience without changing the production backend contract.
Audience: Product, design, and iOS engineering.

## 1. Overview and Goals

Maraithon already has the right top-level shape: native SwiftUI, Magic sign-in, Today, Todos, People, and Chat. The remaining gap is product sharpness. Users should not need to understand the app's internal data model; they should always see the next useful move.

The upgrade must preserve the current architecture while making each tab feel more intentional:

| Surface | Product job |
|---|---|
| Today | Decide what matters now and route directly into action. |
| Todos | Clear open commitments with obvious urgency and quick capture. |
| People | Maintain relationships as a personal CRM, not a sales pipeline. |
| Chat | Act like the Chief-of-Staff pane: draft, summarize, and prioritize quickly. |

## 2. Current-State Audit

### 2.1 Strengths

- The app uses native `TabView`, `NavigationStack`, `List`, `Form`, `sheet`, `.searchable`, and SwiftData.
- Top-level navigation is stable and predictable.
- Magic sign-in and production verification already exist.
- Today now frames the app as a Chief-of-Staff command center.
- Filtering/search helpers are mostly pure and testable.

### 2.2 Gaps to Fix in This Pass

| Gap | Impact | Fix |
|---|---|---|
| Command rows are private to Today. | Other surfaces repeat or under-express actions. | Extract a small shared `CommandRow` design primitive. |
| Contact rows show status/stage, but not relationship care. | Personal CRM users need "who needs attention?" more than pipeline taxonomy. | Add deterministic relationship-care insight and render it in rows/details. |
| Contact detail lacks a strong next action. | Users can view a person but not quickly close the loop. | Add a care recommendation section with Mark Contacted and Create Follow-up. |
| Todo capture defaults to a due date. | Fast capture creates accidental due dates. | Default new todos to no due date; enable due dates intentionally or via suggested follow-up. |
| Todo due labels are visually neutral. | Late/today work does not scan fast enough. | Add urgency-aware due copy and tint in todo rows. |
| Contact creation requires a relationship/context value. | Personal CRM capture should support people without a company/context yet. | Require name + valid email only; use a safe fallback context. |
| Chat quick prompts are hidden behind a plus menu. | The Chief-of-Staff behavior is discoverable too late. | Add visible prompt chips above the composer when the draft is empty. |
| Chat list has no search. | Users need to find prior conversations quickly. | Add pure chat-thread filtering and native `.searchable`. |
| Production verification can race one-time magic tokens. | Verification should be reliable, not flaky. | Keep the hardened fresh-token test loop and run it after this pass. |

## 3. Design Principles

- Native first: use SwiftUI system navigation, lists, forms, search, sheets, SF Symbols, semantic typography, and system colors.
- Dense but calm: information screens should be scannable without dashboard bloat.
- Action over decoration: every prominent surface should route somewhere or mutate useful state.
- Personal CRM language: prefer "People", "Needs Care", "Follow-up", "Context", and "Relationship" over sales terms.
- DRY where it matters: share row primitives and pure judgment logic; keep feature-specific UI inside feature folders.
- Verifiable behavior: product logic must have unit tests, and production flows must pass against `maraithon.com`.

## 4. Scope and Non-Goals

### 4.1 In Scope

- Add shared command/action row UI.
- Add relationship-care insight helper with tests.
- Improve People rows and detail next-action affordances.
- Let Contact Detail create a linked follow-up todo.
- Improve Todo row urgency rendering and new todo defaults.
- Add visible Chat quick prompts and chat search.
- Update or add focused unit tests.
- Run build, unit tests, production simulator verification, simulator launch, and final screenshot review.

### 4.2 Non-Goals

- No backend schema changes.
- No new third-party dependencies.
- No custom tab bar or custom navigation framework.
- No push notifications, widgets, or server-side ranking in this pass.
- No broad MVVM migration or new architecture layer.

## 5. Functional Requirements

### 5.1 People and Relationship Care

- The app must compute a deterministic care summary per contact:
  - archived contacts remain low urgency;
  - `atRisk` contacts always show as needing care;
  - contacts with no last contact show as needing a first touch;
  - contacts with 14+ days since last contact show as needing care;
  - contacts with 7-13 days since last contact show as due for a touch;
  - recently contacted active contacts show as warm.
- Contact rows must show a human relationship context line, including last-contact care state.
- Contact detail must show a care recommendation section near the top.
- Contact detail must let the user mark the person contacted.
- Contact detail must let the user create a linked follow-up todo with a suggested title and due date.
- Contact creation must require only name and valid email; relationship/context can be added later.

### 5.2 Todos

- New todos must default to no due date unless a caller provides a suggested due date.
- Todo rows must render due state clearly:
  - late work uses urgent copy/tint;
  - due-today work is visually distinct;
  - future dates remain calm;
  - completed todos stay subdued.
- Existing production create/update behavior must remain compatible.

### 5.3 Chat

- Chat thread list must support native search.
- Search should match thread title and message bodies.
- Empty search results must show an appropriate empty state.
- Chat detail must show visible quick prompt chips above the composer when the draft is empty.
- Prompt chips must send the prompt immediately, matching the existing plus-menu behavior.
- Composer behavior must remain Telegram-like: bottom safe-area composer, quick send button, scroll-to-bottom.

### 5.4 Shared UI

- Reusable command rows must live in `Core/DesignSystem`.
- Feature screens should use the shared row only where it improves consistency.
- The shared row must use native `Button`, SF Symbols, semantic text styles, Dynamic Type-friendly layout, and accessibility labels.

## 6. Technical Design

| Component | Change |
|---|---|
| `Core/DesignSystem/CommandRow.swift` | New reusable compact action row. |
| `Features/CRM/RelationshipCareInsight.swift` | New pure relationship-care helper. |
| `ContactRow` | Render relationship care context and status/care pills. |
| `ContactDetailView` | Add care recommendation, mark-contacted action, and linked follow-up creation. |
| `ContactEditorView` | Make context optional and keep validation focused on name/email. |
| `TodoEditorView` | Support suggested linked-contact follow-up and default new todos to no due date. |
| `TodoRow` | Add due-state copy/tint. |
| `Features/Chat/ChatThreadFiltering.swift` | New pure thread search helper. |
| `ChatThreadsView` | Add `.searchable` and filtered rendering. |
| `ChatDetailView` | Add visible prompt chips above composer. |
| Tests | Add relationship-care and chat-thread filtering coverage; keep existing production UI flow passing. |

## 7. Validation Matrix

| Gate | Required result |
|---|---|
| Spec lifecycle | Spec and manifest live under `docs/spectacula`; manifest moves to `done` only after verification. |
| XcodeGen | `xcodegen generate` passes after source additions. |
| Build | iOS Simulator build passes. |
| Unit tests | `MaraithonMobileTests` passes. |
| Production simulator | `scripts/verify-production-simulator.sh` passes against `maraithon.com`. |
| Production assertions | The script confirms todo create/complete and person create/update for `kent@runner.now`. |
| Visual QA | Fresh simulator screenshots are reviewed for Today, Todos, People, and Chat. |
| Spec review | Implementation is compared against every in-scope requirement above. |

## 8. Assumptions

| Assumption | Impact |
|---|---|
| The existing production API is the source of truth. | UX polish must not require backend changes. |
| iOS 26 SwiftUI APIs are available. | Use modern native list/search/sheet behavior. |
| App Store-ready means reliable native behavior, not adding marketing surfaces. | Focus on core workflow quality and verification. |
| Server-side AI ranking is future work. | This pass uses deterministic local insight helpers. |

## 9. Definition of Done

- Every in-scope UX change is implemented.
- New pure helpers have unit tests.
- Existing production UI test still passes.
- Build and tests pass after the final code change.
- Production simulator verification passes after the final code change.
- The verified app is launched in Simulator.
- Final screenshots are captured for visual review.
- Spectacula manifest is moved to `done` with verification evidence.

## 10. Completion Notes

| Area | Result |
|---|---|
| Shared UI | Added `CommandRow` and reused it in Today and Contact Detail. |
| People | Added relationship-care insight, care-aware rows, Contact Detail recommendations, Mark Contacted, and linked follow-up creation. |
| Todos | New todos default to no due date unless suggested by a follow-up flow; todo rows render urgency-aware due labels. |
| Chat | Added chat search, visible New Chat empty action, visible prompt chips, and visual smoke screenshot capture. |
| Production config | Passed through `MARAITHON_VISUAL_SNAPSHOT_DIR` for opt-in visual UI tests. |

## 11. Verification

| Gate | Result |
|---|---|
| XcodeGen | Passed via `xcodegen generate`. |
| Build | Passed via `xcodebuild -project MaraithonMobile.xcodeproj -scheme MaraithonMobile build`. |
| Unit tests | Passed via `xcodebuild ... -only-testing:MaraithonMobileTests test`. |
| Visual smoke UI test | Passed and captured `today.png`, `todos.png`, `people.png`, `chat.png`, and `chat-detail.png` in `build/verification/app-store-polish`. |
| Production simulator | Passed for run `20260526025221` against `maraithon.com`. |
| Production assertions | Todo created/completed and person created/updated for `kent@runner.now`. |
| Script syntax | Passed via `bash -n scripts/verify-production-simulator.sh`. |
| Manifest JSON | Passed via `jq empty`. |
| Simulator launch | Passed with `com.bliss.maraithonmobile` launched after production verification. |
