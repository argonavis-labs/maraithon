---
created_at: 2026-05-20T13:42:00Z
created_by: codex
project: Maraithon App
status: done
---
# CRM People Browser UI

Status: Done
Purpose: Add a clean, searchable CRM people view to the authenticated Maraithon operator UI.

## Current State

Maraithon already has a first-class CRM data layer in `Maraithon.Crm`:

- `crm_people` records are user-scoped and include display name, contact details, relationship, preferred communication method, communication frequency, interaction count, relationship strength, affinity score, last interaction timestamp, status, notes, and metadata.
- `Maraithon.Crm.list_people/2` supports user-scoped listing and substring search with a default active status filter.
- The app navigation and operational pages use Catalyst-aligned Phoenix components in `core_components.ex`, row-oriented layouts, restrained borders, and compact tables.

There is no operator-facing CRM browser yet.

## Goals

- Add an authenticated People page where the operator can visualize CRM people.
- Provide a single search input that filters by name, notes, and contact details through `Maraithon.Crm.list_people/2`.
- Keep the page clean, compact, and row-oriented.
- Show the highest-signal CRM fields in the first version: person, relationship, preferred channel, recent activity, interactions, and status.
- Add sidebar navigation so CRM is discoverable from the existing dashboard shell.

## Non-Goals

- No create, edit, merge, archive, or delete flows in this pass.
- No account-level connector settings on this page.
- No custom design system, marketing layout, large decorative cards, or nested panels.

## UX Contract

Route: `/operator/people`

Primary layout:

- Use `<Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>`.
- Header title: `People`.
- Header subtitle: concise product context for CRM visibility.
- Filter panel with one search field and a reset action.
- Main content as a compact table inside a shared panel.

Table columns:

| Column | Behavior |
| --- | --- |
| Person | Display name, contact preview, and short notes preview when available |
| Relationship | Relationship label and communication frequency |
| Channel | Preferred communication method |
| Activity | Last interaction timestamp or `Never`, plus interaction count |
| Strength | Relationship strength and affinity score |
| Status | Status badge |

Empty states:

- No CRM data: show `No people found yet.`
- Search with no matches: show `No people match this search.`

Search behavior:

- Search updates the URL query string through LiveView patching.
- Blank search returns the default People page.
- Reset returns to `/operator/people`.

## Data Contract

- Read people with `Maraithon.Crm.list_people(current_user.id, query: q, limit: 100)`.
- Keep the default active-person filtering from the CRM context.
- Do not preload associations in this first pass because the table only reads fields on `Maraithon.Crm.Person`.
- Never trust a user id from params; always use the authenticated LiveView assign.

## Acceptance Checks

- `/operator/people` requires authentication through the existing authenticated LiveView session.
- Sidebar includes a `People` item and highlights it on the People route.
- The page renders CRM people for the signed-in user only.
- Search filters the list and patches the URL.
- Reset clears the search and returns to the base People route.
- The UI uses shared primitives and follows `DESIGN.md`.
- Focused LiveView tests cover rendering, nav highlighting, search, reset, and user scoping.
- `mix precommit` passes.

## Implementation Result

Implemented on 2026-05-20:

- Added `MaraithonWeb.PeopleLive` at `/operator/people`.
- Added a `People` sidebar navigation item with active-route highlighting.
- Added a compact CRM people table with search, reset, contact preview, relationship, preferred channel, activity, strength, affinity, and status.
- Added focused LiveView tests for signed-in user scoping, nav highlighting, search, and reset.

Verification:

- `mix test test/maraithon_web/live/people_live_test.exs` passed: 2 tests, 0 failures.
- `mix test test/maraithon/assistant_harness_test.exs` passed: 22 tests, 0 failures.
- `mix precommit` passed: 1868 tests, 0 failures.
