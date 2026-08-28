# Claude Instructions

Follow `AGENTS.md` for engineering rules and `DESIGN.md` for product UI direction.

## Deploys

- Production runs on GCP Cloud Run (project `maraithon`, region `us-central1`, Cloud SQL `maraithon-db`). Every push to `main` deploys through `.github/workflows/deploy-gcp.yml` (`make deploy` → `scripts/monorepo/deploy`: Cloud Build → migrate job → `gcloud run deploy` → Todo validation gate).
- A local `make deploy` needs `gcloud` access to the `maraithon` project and `MARAITHON_AGENT_TERMINATION_ATTESTATION_PUBLIC_KEY` (64 hex chars; CI reads it from the repo variable `AGENT_TERMINATION_ATTESTATION_PUBLIC_KEY`).
- Read-only production DB checks: execute the `maraithon-todo-validation` or `maraithon-migrate` Cloud Run job with `--args="^@^eval@<elixir>"` and `--update-env-vars POOL_SIZE=2`; read the printed marker back with `gcloud logging read`. Never `GRANT` anything to the six canonical `maraithon_*` database roles: the readiness proofs fingerprint their memberships and every new revision will refuse to boot.
- Incident-role work (task/agent termination attestations) uses `MARAITHON_INCIDENT_DATABASE_URL`; see `docs/exact-agent-runtime-cutover.md`.
- Never commit Fly/GCP tokens, operator credentials, API tokens, database URLs, or OAuth secrets.

## Current Verification Mode

- Product iteration is currently production-first. Until Kent explicitly re-enables broad test runs, do not run `mix test`, `mix precommit`, `make test`, `make verify`, Xcode test actions, SwiftPM tests, or other expensive test suites by default.
- Use compile/build sanity checks only, scoped to the changed slice.
- Do not delete or weaken tests; just avoid spending time on broad test execution during this phase.

## Testing Principle

- Tests are there for a reason and must not be ignored, worked around, or gamed to look green. A failing test means either the production code has a real issue, or the test no longer represents valid product behavior and should be deliberately removed or rewritten with that rationale. Use the test suite as the highest-leverage harness for moving fast safely: understand what each failing test is trying to protect, then fix the underlying code or retire obsolete coverage intentionally.

## Design Defaults

- Use the Catalyst/Tailwind UI look and feel from `DESIGN.md` on every app surface.
- Find components before building components: check `core_components.ex`, then `/Users/kent/bliss/aitools/catalyst-ui-kit`, then the Catalyst docs.
- Do not invent one-off UI systems or repeated raw Tailwind strings when a shared primitive or Catalyst pattern exists.
- Keep Maraithon clean, minimal, and row-oriented.
- Summary pages should show rollups, not raw detail. Connector summary rows show how many accounts are connected; the detail page owns individual account rows.
- Make drill-in rows clickable and keep secondary actions compact.
- Avoid gradient heroes, nested cards, heavy shadows, and decorative layout.
