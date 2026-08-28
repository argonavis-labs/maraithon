# Claude Instructions

Follow `AGENTS.md` for engineering rules and `DESIGN.md` for product UI direction.

## What this app is

Maraithon is a todo list kept current by an always-on Chief of Staff agent.
It reads a user's inbox, calendar, and Slack, turns commitments into ranked
todos, closes them when evidence arrives, and briefs the user. Prioritize
changes that make the todo list more accurate, timelier, or easier to act on.
Connector and runtime pages are operational surfaces: quiet, row-oriented.

## Runtime and deploys

- Production runs on GCP Cloud Run (project `maraithon`, region `us-central1`, Cloud SQL `maraithon-db`). Every push to `main` deploys through `.github/workflows/deploy-gcp.yml` (`make deploy` → `scripts/monorepo/deploy`: Cloud Build → migrate job → drain the serving revision → `gcloud run deploy` → Todo validation gate).
- The runtime is the exact OTP runtime described in `AGENTS.md`: PostgreSQL owns leases and proofs, the coordination `Session` renews them, each user's Chief of Staff is a `gen_statem` with a restart guard and checkpoints, and recurring schedules discover work. The Chief of Staff must wake every 10 minutes and recurring schedules every 1 to 30 minutes; verify with the "Runtime health" checklist in `AGENTS.md` before declaring anything fixed.
- A local `make deploy` needs `gcloud` access to the `maraithon` project and `MARAITHON_AGENT_TERMINATION_ATTESTATION_PUBLIC_KEY` (64 hex chars; CI reads it from the repo variable `AGENT_TERMINATION_ATTESTATION_PUBLIC_KEY`).
- Read-only production checks: execute the `maraithon-todo-validation` or `maraithon-migrate` Cloud Run job with `--args="^@^eval@<elixir>"` and `--update-env-vars POOL_SIZE=2`; read the printed marker back with `gcloud logging read`. The `eval` string must not contain `@`.
- Never `GRANT` anything to the six canonical `maraithon_*` database roles; the readiness proofs fingerprint their memberships and new revisions refuse to boot.
- Incident-role work (task/agent termination attestations after a node dies with unproven work) uses the incident operator role with real destruction evidence; see `docs/exact-agent-runtime-cutover.md`.
- Never commit GCP tokens, operator credentials, API tokens, database URLs, or OAuth secrets.

## Current Verification Mode

- Product iteration is currently production-first. Until Kent explicitly re-enables broad test runs, do not run `mix test`, `mix precommit`, `make test`, `make verify`, Xcode test actions, SwiftPM tests, or other expensive test suites by default.
- Use `mix compile --warnings-as-errors` and build sanity checks scoped to the changed slice; running the single test file you touched is fine.
- Do not delete or weaken tests; just avoid spending time on broad test execution during this phase.

## Testing Principle

- Tests are there for a reason and must not be ignored, worked around, or gamed to look green. A failing test means either the production code has a real issue, or the test no longer represents valid product behavior and should be deliberately removed or rewritten with that rationale. Use the test suite as the highest-leverage harness for moving fast safely: understand what each failing test is trying to protect, then fix the underlying code or retire obsolete coverage intentionally.

## Design Defaults

- Use the Catalyst/Tailwind UI look and feel from `DESIGN.md` on every app surface.
- Find components before building components: check `core_components.ex`, then `/Users/kent/bliss/aitools/catalyst-ui-kit`, then the Catalyst docs.
- Do not invent one-off UI systems or repeated raw Tailwind strings when a shared primitive or Catalyst pattern exists.
- Keep Maraithon clean, minimal, and row-oriented; the todo list is the product, everything else supports it.
- Summary pages should show rollups, not raw detail. Connector summary rows show how many accounts are connected; the detail page owns individual account rows.
- Make drill-in rows clickable and keep secondary actions compact.
- Avoid gradient heroes, nested cards, heavy shadows, and decorative layout.
