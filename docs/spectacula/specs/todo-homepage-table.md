# Todo Homepage Table Specification

Status: Done
Purpose: Define the dashboard todo-app surface, affected modules, interaction contract, and validation scope.

## 1. Overview and Goals

Maraithon's authenticated homepage at `/dashboard` should read first as a clean todo inbox. The current dashboard already persists actionable work in `Maraithon.Todos` and renders a short "Today" list, but the surface behaves like a dashboard summary rather than an operational todo app.

The v1 change makes todos the primary first-screen object:

- Show open and snoozed todos in a compact Gmail-style table.
- Let the operator multi-select rows.
- Show bulk actions only when one or more rows are selected.
- Let the operator open a todo detail view by clicking a row.
- Preserve the existing dashboard sections below the todo inbox.

## 2. Current State and Problem

Current code:

| Area | Current behavior |
|---|---|
| Route | `live "/dashboard", DashboardLive, :index` in an authenticated LiveView session |
| Data source | `Maraithon.Todos.list_for_user(user_id, limit: 50, statuses: ["open", "snoozed"])` |
| Rendered list | `Enum.take(todos, 6)` as a loose list under "Today" |
| Actions | Per-row Mark done and Dismiss events |
| Detail view | None |
| Selection | None |

Problem: the homepage underuses the durable todo model. Operators cannot scan all open work like an inbox, cannot act on multiple todos at once, and cannot drill into the full record without leaving the page.

## 3. Scope and Non-Goals

In scope:

- Update `MaraithonWeb.DashboardLive` only unless tests require support helpers.
- Use existing `Todos` context APIs; do not add database fields.
- Render all loaded open/snoozed todos, not only the first six.
- Add LiveView state for selected todo ids and the currently opened todo.
- Add tests for table rendering, bulk actions, and detail drill-in.

Out of scope:

- New todo creation UI.
- New filters, search, drag-and-drop, labels, or keyboard shortcuts.
- Connector source deep links.
- Schema migrations.
- Replacing the rest of the dashboard.

## 4. UX / Interaction Model

### 4.1 Layout

`/dashboard` starts with a compact header and the todo table. The table uses existing Catalyst-aligned primitives and row styling from `core_components.ex` where practical.

Rows should be dense and scannable:

| Column | Contents |
|---|---|
| Select | Checkbox for row selection |
| Todo | Status badge, title, summary, next action |
| Source | Source label and account label when available |
| Priority | Numeric priority |
| Updated | Last update timestamp |
| Actions | Quiet per-row Mark done and Dismiss |

### 4.2 Multi-Select

- Selecting a checkbox adds that todo id to `selected_todo_ids`.
- Unselecting removes it.
- The header checkbox selects or clears all currently visible todos.
- After refreshes or actions, selection is intersected with the currently visible open/snoozed todo ids.
- A selected row is visually distinct without heavy color.

### 4.3 Bulk Actions

When `selected_todo_ids` is not empty, show a compact toolbar above the table with:

- Selected count.
- Mark done.
- Dismiss.
- Clear selection.

Bulk actions call the same `Todos.mark_done/3` and `Todos.dismiss/3` APIs as per-row actions. Successful bulk actions refresh the dashboard, clear completed/dismissed ids from selection, and show a flash with the affected count.

### 4.4 Detail Drill-In

- Clicking a todo row opens a detail panel on the same page.
- The selected detail is URL-backed with `?todo_id=<id>` so refresh/back navigation preserves context.
- The detail panel shows title, status, source, priority, summary, next action, due/snooze/update timestamps, notes, action plan, and source metadata when present.
- Closing the detail panel patches back to `/dashboard`.
- If the requested todo id does not belong to the current user or no longer exists, the panel is not shown.

## 5. Functional Requirements

| ID | Requirement |
|---|---|
| FR-1 | The dashboard lists up to 50 open/snoozed todos in table form. |
| FR-2 | The open count reflects all loaded open/snoozed todos. |
| FR-3 | Per-row Mark done and Dismiss continue to work. |
| FR-4 | Multi-select state supports individual toggle, select all visible, clear all. |
| FR-5 | Bulk Mark done and Dismiss apply only to selected ids belonging to the current user. |
| FR-6 | Bulk action failures for missing ids do not crash the LiveView. |
| FR-7 | Row click opens a detail panel for that todo without leaving `/dashboard`. |
| FR-8 | The detail panel is driven by `todo_id` query params and scoped to the current user. |
| FR-9 | The rest of the dashboard remains available below the todo inbox. |

## 6. Data and Domain Model

No schema change. The UI reads `Maraithon.Todos.Todo` fields:

- `id`
- `status`
- `source`
- `source_account_label`
- `metadata`
- `title`
- `summary`
- `next_action`
- `priority`
- `due_at`
- `snoozed_until`
- `updated_at`
- `notes`
- `action_plan`

LiveView assigns:

| Assign | Type | Source |
|---|---|---|
| `todos` | list of `%Todo{}` | `Todos.list_for_user/2` |
| `open_todo_count` | integer | length of loaded todos |
| `selected_todo_ids` | `MapSet.t()` | LiveView events |
| `selected_todo_id` | string or nil | `todo_id` query param |
| `selected_todo` | `%Todo{}` or nil | `Todos.get_for_user/2` |

## 7. Backend / Service Changes

No new public context API is required. Bulk events can reuse existing one-at-a-time context calls:

```elixir
selected_ids
|> Enum.reduce({0, []}, fn todo_id, {count, errors} ->
  case Todos.mark_done(user_id, todo_id, note: "Completed from dashboard bulk action.") do
    {:ok, _todo} -> {count + 1, errors}
    {:error, reason} -> {count, [{todo_id, reason} | errors]}
  end
end)
```

## 8. Frontend / UI Changes

Implementation target: `lib/maraithon_web/live/dashboard_live.ex`.

Required event handlers:

- `toggle_todo_selection`
- `toggle_all_todos`
- `clear_todo_selection`
- `complete_selected_todos`
- `dismiss_selected_todos`
- `open_todo_detail`

Required helper behavior:

- `refresh_todos/1` must keep selection valid after todo status changes.
- `apply_dashboard_params/3` must read `todo_id` without conflicting with legacy agent `id` redirects.
- Formatting helpers should avoid raw internal values when a cleaner label already exists.

## 9. Failure Modes and Edge Cases

| Case | Expected behavior |
|---|---|
| No todos | Short empty state remains visible. |
| Selected todo is completed by another refresh | Selection drops the id on refresh. |
| Bulk action includes stale id | Ignore stale id, show success for changed records, keep page responsive. |
| `todo_id` query param is invalid | No detail panel. |
| Todo has missing optional fields | Omit empty detail rows. |
| Long title/summary | Wrap text inside the table cell; do not expand layout horizontally. |

## 10. Test Plan and Validation Matrix

| Test | Validation |
|---|---|
| Existing dashboard smoke test | Existing dashboard sections still render. |
| Single todo action test | Per-row completion still removes the todo. |
| Table render test | Multiple todos appear as table rows with source, priority, and next action. |
| Multi-select bulk done test | Selecting two todos and clicking bulk Mark done closes both. |
| Detail test | Opening `/dashboard?todo_id=<id>` renders the todo detail panel. |

Project gate:

- Run `mix precommit` after implementation and fix failures.

## 11. Definition of Done

- `/dashboard` presents todos as the primary table-first surface.
- Multi-select and bulk actions work against persisted todos.
- Todo detail drill-in works through a URL param.
- Existing dashboard capabilities remain available.
- Focused LiveView tests pass.
- `mix precommit` passes, or any blocker is recorded explicitly.

## 12. Assumptions

- "Homepage" means the authenticated operator homepage at `/dashboard`, matching the provided screenshot.
- "All of these should be the todos" means the current open/snoozed `Todos` rows should be rendered in the main table instead of only showing six items.
- A same-page detail panel is sufficient for v1; a separate `/todos/:id` route can be added later if the app grows a standalone Todos section.
