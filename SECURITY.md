# Security

Maraithon handles connected accounts, messages, calendar entries, and personal
context. Treat that data as sensitive even when it appears in a debug report
or a test fixture.

## Report a vulnerability

Use [GitHub's private vulnerability reporting form](https://github.com/argonavis-labs/maraithon/security/advisories/new).
Include the affected revision, a minimal reproduction with synthetic data, and
the impact you observed. Do not include working credentials or someone else's
messages. Do not open a public issue for an unpatched vulnerability.

The project is experimental and has no supported release series or guaranteed
response time. Security fixes target the current `main` branch.

## Credentials and personal data

- Keep local secrets in ignored files. Keep hosted secrets in your secret manager.
- Use your own OAuth applications, accounts, signing identities, and cloud project.
- Never commit API keys, database URLs containing passwords, private signing
  keys, database dumps, raw provider responses, or personal source records.
- Review diagnostics and screenshots before sharing them. Automated redaction
  is useful, but it is not proof that an artifact contains no personal data.
- If a real credential reaches Git, revoke or rotate it. Deleting the latest
  copy does not remove earlier commits, forks, caches, or downloaded copies.

The development database credentials, Phoenix development secret, and
development vault key are intentionally public local fixtures. Hosted instances
must supply their own credentials and keys and retain the production startup
checks.

## Runtime and send authority

Connecting a source is not permission to send messages. Keep delegation gates,
account ownership checks, and explicit user approval requirements intact.
Never use a shared assistant identity across unrelated users.

Database leases and task fences protect durable ownership. Do not bypass them
to make a deployment or local setup succeed. Production runtime activation,
termination attestations, and key retirement require the operator procedures
in `docs/operations` and `docs/exact-agent-runtime-cutover.md`.
