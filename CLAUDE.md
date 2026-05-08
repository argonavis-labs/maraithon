# Claude Instructions

Follow `AGENTS.md` for engineering rules and `DESIGN.md` for product UI direction.

## Design Defaults

- Use the Catalyst/Tailwind UI look and feel from `DESIGN.md` on every app surface.
- Find components before building components: check `core_components.ex`, then `/Users/kent/bliss/aitools/catalyst-ui-kit`, then the Catalyst docs.
- Do not invent one-off UI systems or repeated raw Tailwind strings when a shared primitive or Catalyst pattern exists.
- Keep Maraithon clean, minimal, and row-oriented.
- Summary pages should show rollups, not raw detail. Connector summary rows show how many accounts are connected; the detail page owns individual account rows.
- Make drill-in rows clickable and keep secondary actions compact.
- Avoid gradient heroes, nested cards, heavy shadows, and decorative layout.
