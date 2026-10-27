# Design

Maraithon is an operational app. It should feel calm, direct, and built for daily use by busy humans. Do not let the product drift back into decorative dashboards, oversized cards, or one-off Tailwind styling.

## Non-Negotiables

- Find components before building components.
- Use the Catalyst/Tailwind UI look and feel for every app surface.
- Start with existing Phoenix components in `lib/maraithon_web/components/core_components.ex`.
- When the local app does not have the primitive you need, reference `/Users/kent/bliss/aitools/catalyst-ui-kit` before writing custom UI.
- Keep new UI primitives small, reusable, and Catalyst-aligned. Do not create bespoke one-page component systems.
- Do not introduce new visual languages, gradient hero sections, large marketing cards, nested cards, heavy shadows, or oversized rounded corners.
- Prefer row-oriented layouts, tables, lists, compact panels, clear headings, and right-aligned actions.

## Component Sources

Use these sources in this order:

1. App primitives in `core_components.ex`: `panel`, `button`, `badge`, `table`, `description_list`, `field`, `c_input`, `c_textarea`, `c_select`, `alert`, `heading`, and `text`.
2. Local Catalyst kit: `/Users/kent/bliss/aitools/catalyst-ui-kit`.
3. Catalyst docs: https://catalyst.tailwindui.com/docs.
4. New local component only when the first three sources do not cover the need.

When creating a new local component, it should wrap a Catalyst pattern and reduce duplication across surfaces. It should not be a single-use styling wrapper.

## Product UI

- Prefer rows, tables, and concise panels over decorative cards.
- Summary pages show the highest-signal rollup only. Connector summary rows show connector, status, and connected account count.
- Put account-level connector details on the connector detail page as separate rows with status, last update, scopes, health, and actions.
- Agent list rows should use human names, concise outcomes, horizontal connected-account badges, status, and one clear primary action.
- Make drill-in rows clickable. Keep secondary actions compact, right-aligned, and visually quieter than the row content.
- Attached skills and connector settings should read like settings for a human operator, not internal config dumps.
- Keep labels direct. If something requires action, say that clearly and place the suggested action nearby.
- For Chief of Staff output, lead with: what requires action, what it is, suggested reply or next action, and a few actions to take. Do not expose thresholds, scoring internals, or long preambles.

## Visual Rules

- Use white or zinc panels with subtle `border-zinc-950/10`, compact spacing, and restrained shadows.
- Border radius should usually be `rounded-lg` or smaller. Avoid `rounded-2xl`, `rounded-3xl`, and pill-heavy UI unless the component pattern requires it.
- Buttons should use the shared `<.button>` primitive or a Catalyst equivalent.
- Form fields should use `<.field>` with `c_input`, `c_textarea`, or `c_select`.
- Status should use `<.badge>` or a Catalyst-equivalent badge.
- Tables should use shared table primitives for account lists, connector details, logs, and other structured data.
- Avoid raw repeated Tailwind control strings in templates. Extract or reuse a component.
- Avoid visible instructional copy that explains the UI. Prefer clear labels and obvious controls.

## UX Rules

- Optimize for scanning first, then drill-in detail.
- Show account counts on summary rows; show actual accounts on detail pages.
- Keep destructive actions available but visually secondary.
- Only show reconnect actions when a connection is stale, expired, or erroring. Do not show “Reconnect” as the default action for healthy connections.
- Preserve context when navigating: rows should lead to details, details should make it obvious how to go back.
- Empty states should be short, actionable, and specific.
