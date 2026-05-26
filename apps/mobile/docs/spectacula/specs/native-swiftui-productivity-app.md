# Native SwiftUI Productivity App Specification

Status: Complete v1
Purpose: Define and implement a greenfield iOS 26 SwiftUI application with passwordless Magic Signin and three primary tabs: Todos, CRM, and Chat.
Audience: Engineering and product review.

## 1. Overview and Goals

The repository starts empty. The deliverable is a full native SwiftUI mobile app scaffold that can be opened in Xcode, built for iOS Simulator, and used without requiring backend credentials. The app should feel like a modern 2026 iOS application: declarative SwiftUI, first-party persistence, type-safe observation, async-friendly service boundaries, accessible controls, and a clean feature-oriented structure.

### 1.1 Goals

| Goal | Requirement |
|---|---|
| Native iOS app | Build with SwiftUI, Swift 6, iOS 26 SDK, and Xcode project generation. |
| Passwordless entry | Provide a Magic Signin flow for email-based passwordless authentication. |
| Tab navigation | Provide three app tabs: Todos, CRM, and Chat. |
| Persistence | Persist app data locally with SwiftData. |
| Clean architecture | Keep features modular, state boundaries explicit, and shared UI/utilities DRY. |
| Verification | Include a test target and run project-native build/test checks. |

### 1.2 Current-State Context

The working directory has no existing source code, Git metadata, Xcode project, package manifest, or app assets. Implementation must bootstrap the complete app structure in place.

## 2. Scope and Non-Goals

### 2.1 In Scope

- Generate a maintainable Xcode project from a declarative `project.yml` using XcodeGen.
- Create a single iOS application target and a focused test target.
- Implement an authentication gate before the tabbed app shell.
- Implement working Todos, CRM, and Chat features with local sample data and local persistence.
- Use SwiftUI navigation primitives, SwiftData models, the Observation framework, async/await service seams, and system components where appropriate.
- Use SF Symbols and platform styling instead of custom icon systems.

### 2.2 Non-Goals

- Production backend sync.
- Push notifications.
- Real-time chat transport.
- Real AI assistant integration.
- Shipping a real Magic publishable key in source.
- Mandating the Magic iOS SDK at runtime. The public Magic iOS repository is in maintenance mode and the current mobile APIs emphasize email/SMS OTP instead of the removed magic-link API; v1 must isolate auth behind a provider so a production Magic provider can be added without rewriting UI.

## 3. Product and UX Model

### 3.1 Authentication

The first launch shows a polished passwordless sign-in screen. A user enters an email address, submits, and receives a local one-time code for development/demo use. The code verification signs the user into a local session. Sign-out is available from the app shell toolbar/menu.

Production integration must be represented by an `AuthProviding` protocol that can later wrap Magic SDK APIs such as email OTP login, user info, token generation, and logout.

### 3.2 App Shell

After sign-in, the root interface is a `TabView` with:

| Tab | System image | Root flow |
|---|---|---|
| Todos | `checklist` | Task list, filters, add/edit affordances, completion toggles. |
| CRM | `person.2.crop.square.stack` | Contact pipeline summary, contact list, contact detail, deal stage updates. |
| Chat | `bubble.left.and.bubble.right` | Thread list, message detail, composer, local assistant response. |

Each tab owns its own `NavigationStack` so navigation state remains scoped and predictable.

### 3.3 Feature Behavior

Todos:
- Show open/completed counts.
- Filter by all, today, upcoming, and completed.
- Add a todo with title, notes, priority, due date, and optional contact relationship.
- Toggle completion inline.
- Delete todos from list rows.

CRM:
- Show pipeline value grouped by deal stage.
- List contacts with company, status, latest note, and deal value.
- Add contacts.
- Drill into a contact detail screen.
- Update deal stage and add lightweight notes.

Chat:
- Show a list of local chat threads.
- Open a thread and view messages.
- Send a message from a composer.
- Append a deterministic local assistant response to demonstrate the loop.
- Persist messages and threads locally.

## 4. Technical Architecture

### 4.1 Project Structure

```text
MaraithonMobile/
  App/
  Core/
    Auth/
    DesignSystem/
    Models/
    Persistence/
    Utilities/
  Features/
    AppShell/
    Auth/
    Todos/
    CRM/
    Chat/
MaraithonMobileTests/
project.yml
```

### 4.2 Frameworks and Libraries

| Layer | Choice | Reason |
|---|---|---|
| UI | SwiftUI | Native declarative UI and platform controls. |
| Navigation | `TabView`, `Tab`, `NavigationStack` | Current first-party navigation model for tabbed apps. |
| State | Observation `@Observable` | Type-safe model observation without legacy `ObservableObject` boilerplate. |
| Persistence | SwiftData `@Model`, `ModelContainer`, `@Query` | First-party object persistence integrated with SwiftUI. |
| Auth surface | Custom `AuthProviding` protocol plus local provider | Keeps app buildable without secrets while preserving a provider swap point. |
| Project generation | XcodeGen | Avoids manual `.pbxproj` churn in a greenfield repo. |
| Tests | Swift Testing / XCTest-compatible test bundle | Validate pure domain logic and auth session behavior. |

### 4.3 Dependency Rules

- Prefer Apple frameworks when they cover the requirement.
- Do not add third-party runtime dependencies for simple local behavior.
- Do not commit secrets, publishable keys, or generated user data.
- Keep service dependencies protocol-based and injected through SwiftUI environment values or explicit initializers.

## 5. Data and Domain Model

### 5.1 SwiftData Models

| Model | Fields |
|---|---|
| `TodoItem` | `id`, `title`, `notes`, `priority`, `dueDate`, `isCompleted`, `createdAt`, `completedAt`, optional `contact` |
| `CRMContact` | `id`, `name`, `company`, `email`, `phone`, `status`, `dealValue`, `dealStage`, `lastContactedAt`, `notes`, relationship `todos` |
| `ChatThread` | `id`, `title`, `createdAt`, `updatedAt`, relationship `messages` |
| `ChatMessage` | `id`, `body`, `sentAt`, `role`, relationship `thread` |

### 5.2 Domain Enums

| Enum | Values |
|---|---|
| `TodoPriority` | `low`, `medium`, `high` |
| `ContactStatus` | `lead`, `active`, `atRisk`, `closed` |
| `DealStage` | `prospect`, `qualified`, `proposal`, `won`, `lost` |
| `ChatRole` | `user`, `assistant`, `system` |

Enums must be `Codable`, `CaseIterable` where useful, and persistable through raw values.

### 5.3 Seed Data

On first app launch, if the persistent store is empty, insert a small set of realistic sample todos, contacts, chat threads, and messages. Seeding must be idempotent.

## 6. Implementation Contract

### 6.1 Authentication Contract

```swift
protocol AuthProviding: Sendable {
    func startEmailSignin(email: String) async throws -> MagicSigninChallenge
    func verifyEmailSignin(challengeID: String, code: String) async throws -> AuthenticatedUser
    func restoreSession() async throws -> AuthenticatedUser?
    func signOut() async throws
}
```

Local development behavior:
- Generate a six-digit code.
- Present the code on screen as a development affordance.
- Reject invalid email input before creating a challenge.
- Reject incorrect codes with a user-visible error.
- Persist the signed-in session in `UserDefaults` as non-sensitive demo state only.

Production-ready behavior:
- The UI must not depend on the local provider.
- A Magic SDK provider can later call Magic email OTP APIs and map responses into the same contract.

### 6.2 Persistence Contract

- App startup creates one shared `ModelContainer`.
- Views read and mutate models through SwiftData contexts.
- Mutations that should be durable call `try? modelContext.save()` after insert/update/delete.
- Tests may use in-memory containers.

### 6.3 Error and Empty States

- Auth errors appear inline on the sign-in screen.
- Empty feature lists show useful native content placeholders and primary actions.
- Forms validate required fields before saving.
- Delete and stage-change operations should be immediate and reversible by editing/recreating data; undo manager integration is future work.

## 7. Design and Accessibility Requirements

- Use system materials, lists, forms, toolbars, menus, buttons, and SF Symbols.
- Keep dense operational screens scannable rather than marketing-like.
- Avoid custom fonts, excessive gradients, oversized hero layouts, and visual decoration that weakens utility.
- Respect Dynamic Type by using semantic text styles.
- Provide accessibility labels for icon-only controls and message bubbles where needed.
- Support light and dark mode through system colors.

## 8. Observability and Privacy

V1 has no external analytics. Local debug-friendly state should be visible through app UI where useful, such as counts, statuses, and timestamps. The app must not transmit user input off device.

## 9. Testing and Validation Matrix

| Area | Validation |
|---|---|
| Project generation | `xcodegen generate` succeeds. |
| Build | iOS Simulator app target builds with Swift 6. |
| Tests | Unit tests pass for auth flow, filtering, and deterministic chat response generation. |
| Auth | Invalid email fails; correct code signs in; sign-out clears session. |
| Todos | Add, filter, complete, and delete work. |
| CRM | Contact list, add flow, detail view, stage updates, and notes work. |
| Chat | Thread list, detail, composer, persisted messages, and local response work. |
| Spec review | Implementation is checked against this document before completion. |

## 10. Definition of Done

- The Spectacula spec is saved in `docs/spectacula/specs`.
- A stage manifest tracks implementation and verification state.
- The Xcode project can be regenerated from `project.yml`.
- The app launches into Magic Signin and then into the three-tab app shell.
- Todos, CRM, and Chat are functional with local persistence.
- Tests and build verification have been run, with blockers recorded if any gate cannot pass.
- Final review confirms every in-scope requirement is implemented or explicitly documented as deferred.

## 11. Assumptions

| Assumption | Impact |
|---|---|
| iOS 26 is an acceptable minimum target. | Enables current SwiftUI APIs and avoids legacy compatibility code. |
| Magic Signin means passwordless email sign-in. | V1 implements email OTP-style local sign-in and isolates production auth behind a provider. |
| No backend credentials are available. | The app must be usable offline and cannot call real Magic services. |
| Runtime dependencies should be conservative. | First-party frameworks are preferred unless a library materially reduces complexity. |
