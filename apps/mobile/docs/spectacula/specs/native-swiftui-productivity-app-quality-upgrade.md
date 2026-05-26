# Native SwiftUI Productivity App Quality Upgrade Specification

Status: Complete v1
Purpose: Make the existing iOS 26 SwiftUI productivity app feel more complete, durable, and useful for repeated mobile use.
Audience: Engineering and product review.

## 1. Overview and Goals

The current app has a working native SwiftUI foundation: Magic Signin, tab navigation, SwiftData models, local seed data, and focused tests. The next upgrade should improve the day-to-day product experience without introducing backend dependencies or speculative third-party frameworks.

### 1.1 Goals

| Goal | Requirement |
|---|---|
| Repeated-use utility | Add search, filtering, and edit flows that make existing data manageable. |
| Better mobile ergonomics | Add swipe actions, menus, native sheets, scoped forms, and sensible empty states. |
| Product polish | Add a real app icon, account tools, and clearer context in each tab. |
| Data safety | Replace silent best-effort persistence in user-facing workflows with lightweight save helpers and visible recovery where feasible. |
| Testable domain logic | Add pure helper logic for CRM search/stats and chat thread naming. |

### 1.2 Current-State Context

The app currently supports:
- Local passwordless sign-in with a development code.
- Todos with segmented filters, add, complete, and delete.
- CRM with contact list, add, detail, stage/status update, and notes.
- Chat with local threads, message composer, and deterministic assistant response.

The main gaps are:
- No search in Todos or CRM.
- Todos cannot be edited after creation.
- CRM detail does not provide a complete edit surface for core fields.
- Chat thread naming and message lifecycle are basic.
- Account menu only signs out.
- App packaging intentionally disabled the app icon requirement.

## 2. Scope and Non-Goals

### 2.1 In Scope

- Add AppIcon asset catalog content and a generated local icon image set.
- Add account tools for resetting demo data and clearing the local session state.
- Add Todo search, overdue filter, edit screen, row swipe actions, and a higher-signal list summary.
- Add CRM search/filter helpers, stage summaries, richer contact edit flow, and row swipe actions for quick stage updates.
- Add chat quick prompts, better automatic thread titles, message deletion, and deterministic naming logic.
- Add targeted tests for new domain helpers.

### 2.2 Non-Goals

- Backend sync or cloud persistence.
- Real Magic SDK provider implementation.
- Real AI or LLM chat integration.
- Push notifications, background refresh, widgets, Live Activities, or App Intents.
- A full custom design system beyond reusable primitives needed by this scope.

## 3. UX Upgrade Contract

### 3.1 Account Menu

The account menu must include:
- Signed-in email.
- Reset Demo Data.
- Sign Out.

Reset Demo Data deletes all SwiftData Todo, CRM, ChatThread, and ChatMessage records, then reseeds the demo dataset. The action must require confirmation.

### 3.2 Todos

Todos must support:
- Search by title, notes, priority, and linked contact name.
- Filters: all, today, overdue, upcoming, completed.
- Editing an existing todo from row tap or explicit edit action.
- Swipe actions for complete/incomplete, edit, and delete.
- Count summary for open, overdue, and done.

### 3.3 CRM

CRM must support:
- Search by contact name, company, email, phone, status, deal stage, and notes.
- A segmented status filter.
- Swipe actions to mark a contact active, mark contacted, or move a deal to won.
- A complete edit sheet from detail view for contact fields, status, stage, value, and notes.
- Pipeline stage summaries must continue to work with filtered and unfiltered data.

### 3.4 Chat

Chat must support:
- Quick prompt chips for common productivity actions.
- Better automatic thread titles derived from the first user message.
- Message deletion from a thread.
- New chat creation should navigate cleanly through the thread list and preserve local persistence.

## 4. Technical Design

### 4.1 Design Principles

- Keep feature code feature-owned; use shared helpers only when reuse is real.
- Keep pure domain logic in small enums/structs so tests do not need UI or SwiftData runtime where avoidable.
- Prefer native SwiftUI modifiers such as `.searchable`, `.confirmationDialog`, `.swipeActions`, `.toolbar`, `.sheet`, and `ContentUnavailableView`.
- Keep the app offline-first and deterministic.

### 4.2 New/Changed Components

| Component | Change |
|---|---|
| `DataSeeder` | Add reset support and seed helper reuse. |
| `AccountMenuButton` | Accept reset action and show confirmation. |
| `TodoFilter` / `TodoFiltering` | Add overdue and search-aware filtering. |
| `TodoEditorView` | Support create and edit mode. |
| `CRMFiltering` | Add pure search/status filtering and pipeline value helpers. |
| `ContactEditorView` | Support create and edit mode. |
| `ChatThreadNaming` | Add deterministic title derivation. |
| `ChatDetailView` | Add quick prompts and message delete support. |
| Asset catalog | Add `AppIcon.appiconset` and generated PNGs. |

## 5. Data and Persistence

No schema migration is required. All changes use existing fields. Reset must delete records in relationship-safe order:

1. `ChatMessage`
2. `ChatThread`
3. `TodoItem`
4. `CRMContact`

After deletion, seeding inserts the known demo dataset and saves the model context.

## 6. Failure Handling

- Failed saves should not crash the app.
- Reset failure should leave the user signed in and show a visible local error.
- Edit forms must keep save buttons disabled while required fields are invalid.
- Search should degrade to an empty list, not an error state.

## 7. Test Plan and Validation Matrix

| Area | Validation |
|---|---|
| Project generation | `xcodegen generate` succeeds. |
| Build | App target builds on iOS Simulator. |
| Tests | Existing and new unit tests pass. |
| Todo filtering | Overdue and search-aware filtering behave deterministically. |
| CRM filtering | Search/status filtering and value helpers behave deterministically. |
| Chat naming | First-message title derivation is stable and length-bounded. |
| Account reset | Reset helper compiles and is wired behind confirmation. |
| Spec review | Implementation is checked against this spec before completion. |

## 8. Definition of Done

- The quality upgrade spec and manifest are tracked under `docs/spectacula`.
- The app has an app icon and Xcode no longer disables `ASSETCATALOG_COMPILER_APPICON_NAME`.
- Todos, CRM, Chat, and account menu all receive the in-scope UX upgrades.
- New tests cover pure helper logic.
- `xcodegen generate`, build, and tests have run successfully or blockers are recorded.
- Final review confirms the implementation matches this spec.

## 9. Assumptions

| Assumption | Impact |
|---|---|
| The app remains offline-first. | Avoid backend, sync, auth provider, and LLM dependencies. |
| The three primary tabs remain Todos, CRM, and Chat. | Improvements deepen existing tabs instead of adding new top-level navigation. |
| iOS 26 remains the minimum target. | Use current SwiftUI affordances without compatibility fallbacks. |
| Product decisions are delegated. | Proceed without additional clarification and choose pragmatic defaults. |
