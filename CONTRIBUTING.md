# Contributing to Maraithon

Maraithon helps people know what matters, prepare for their day, and follow
through. Changes should make a todo more trustworthy, improve preparation, or
help the application do useful work reliably.

## Start here

Follow the [local setup](README.md#run-locally), then read [AGENTS.md](AGENTS.md)
and the [development policy](docs/development-mode.md). Read the app-specific
`AGENTS.md` before changing a native client. UI changes follow [DESIGN.md](DESIGN.md).

Create a branch from `main`. Keep the change focused and explain the problem
it solves. Open an issue before a large redesign so we can agree on the scope.

## Check your change

```sh
make build
```

This compiles Phoenix with warnings treated as errors. Use the narrowest
relevant build for native or asset changes. Format the files you edit using the
project's formatter.

The project currently uses a manual-first workflow. `make test` and
`make verify` also compile; their names do not mean tests ran. Do not add
or run automated tests unless the task explicitly requests testing or
hardening. Keep the existing suites intact. If testing is requested, fix the
cause of a failure rather than skipping or weakening the check.

In your pull request, describe:

- The problem and the resulting behaviour.
- The build or other checks you ran, including any limitations.
- The manual steps needed to review the change.
- Whether tests were intentionally not run under the current policy.

Builds and contributions do not require access to the maintainer's cloud
project, Apple team, or personal accounts. Deployment workflows are opt-in
maintainer operations, described in the [workflow guide](.github/workflows/README.md).

## Code and data

- Use the existing components and abstractions before introducing new ones.
- Use `Req` for Elixir HTTP requests.
- Preserve database ownership, fencing, and task-outcome guarantees.
- Keep provider calls outside coordination loops and bound retries and concurrency.
- Use synthetic identities such as `person@example.com` in examples and fixtures.
- Keep credentials and personal source data out of commits, screenshots, logs,
  issues, and pull requests. `.env.example` contains local placeholders only.

For a connector, document its provider setup, scopes, callback URLs, and failure
behaviour in [the connector guide](docs/connectors.md). For a behaviour, explain
its inputs, permitted actions, and recovery path.

## Security reports

Follow [SECURITY.md](SECURITY.md). Report vulnerabilities privately, not in a
public issue. A secret removed from a file can still exist in Git history.

## Working together

Be respectful and specific. Critique the work, explain your reasoning, and
give other contributors room to improve it. Harassment and sharing someone
else's private information are not acceptable.

Contributions to the project's original code use the [MIT licence](LICENSE).
Preserve third-party copyright and licence notices when changing bundled assets.
