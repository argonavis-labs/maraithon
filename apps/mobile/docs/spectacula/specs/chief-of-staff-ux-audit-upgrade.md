# Chief-of-Staff UX Audit Upgrade Specification

Status: Complete v1
Purpose: Reframe Maraithon from a passive productivity dashboard into an action-oriented Chief of Staff that tells users what deserves attention and routes them directly to the right work.
Audience: Product and engineering.

## 1. Audit Findings

The screenshots show a consistent UX problem: important surfaces look tappable only after prior explanation, and the first screen still spends too much space on counts rather than decisions. A Chief of Staff should not make the user interpret four metrics before acting.

### 1.1 What Users Want To Do

| User intent | Product response |
|---|---|
| Know what matters now | Show one clear briefing with the highest-priority issue and why it matters. |
| Clear commitments | Route to open, late, or due-today todos with the right filter already selected. |
| Maintain relationships | Route to people who need care, not a sales pipeline. |
| Capture new work fast | Keep plus buttons available, but make Today primarily about review and triage. |
| Ask for help | Make Chat feel like the Chief-of-Staff pane for drafting, prioritizing, and summarizing. |

### 1.2 What Users Want From Their Chief Of Staff

- Prioritize the next decision.
- Surface late work and stale relationships before vanity totals.
- Explain state in plain language.
- Provide obvious next actions.
- Avoid making metrics feel like inert decoration.
- Keep navigation predictable: tapping a summary should land in the relevant filtered workflow.

### 1.3 Current Gaps

| Gap | Impact |
|---|---|
| Today uses a greeting card plus metric grid. | Feels like a dashboard, not a staff briefing. |
| Metrics compete equally. | The app does not express what should happen first. |
| Snapshot cards are visually large. | They consume first-screen space that should be reserved for decisions. |
| Chat is not represented as a Chief-of-Staff action on Today. | Users may miss that Chat is where they can ask for help. |
| Todos default to all work. | Completed work can dilute the primary work queue. |

## 2. Upgrade Contract

### 2.1 Today

- Replace the passive snapshot grid with a Chief-of-Staff command center.
- Show a top briefing card with:
  - a recommendation title;
  - a concise reason;
  - one primary action button.
- Show compact action rows for:
  - Open todos;
  - Late todos;
  - Due today;
  - People needing care;
  - Ask the Chief of Staff.
- Each row must be tappable and route directly to the relevant tab/filter.
- Keep the Focus Queue as the evidence list beneath the briefing.

### 2.2 Todos

- Default to `Open`, because users usually come to Todos to do outstanding work.
- Keep `All` available for audit/history.
- Today shortcuts must select the matching filter.

### 2.3 People

- Continue to emphasize relationship care.
- Today shortcuts must select `Needs Care` when follow-up attention is requested.

### 2.4 Chat

- Add Today routing to Chat so users can ask for drafting/prioritization help directly from the command center.

## 3. Technical Design

| Component | Change |
|---|---|
| `TodayInsightEngine` | Add due-today count and a pure `brief` function that returns a recommendation and destination. |
| `TodayView` | Replace metric grid with `TodayBriefCard` and compact `TodayActionRow` components. |
| `AppNavigation` | Add `showChat()`. |
| `TodosView` | Default filter becomes `.open`. |
| Tests | Add brief-priority tests so product logic remains deterministic. |

## 4. Definition Of Done

- This spec and manifest are tracked under `docs/spectacula`.
- Today first screen reads as a Chief-of-Staff briefing, not a passive dashboard.
- All Today actions route somewhere useful.
- The briefing recommendation is deterministic and tested.
- Build, tests, production simulator verification, and simulator launch pass.

## 5. Verification

| Check | Result |
|---|---|
| XcodeGen | Passed via `xcodegen generate`. |
| Build | Passed via `xcodebuild -project MaraithonMobile.xcodeproj -scheme MaraithonMobile build`. |
| Unit tests | Passed via `xcodebuild ... -only-testing:MaraithonMobileTests test`. |
| Production simulator | Passed for run `20260526023525` against `maraithon.com`. |
| Production assertions | Todo created/completed and person created/updated for `kent@runner.now`. |
| Simulator launch | Passed with `com.bliss.maraithonmobile` launched on the configured simulator. |
| Visual check | Passed with `build/verification/chief-of-staff-today-final.png`. |

## 6. Assumptions

| Assumption | Impact |
|---|---|
| User delegated product decisions. | Proceed without asking for label/layout approval. |
| Production data model remains unchanged. | This is a UX and routing upgrade, not a backend/schema change. |
| The app should stay native SwiftUI. | Use list sections, buttons, SF Symbols, materials, and existing tabs. |
