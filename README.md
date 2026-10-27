# Maraithon

Maraithon is an AI Chief of Staff built with Elixir, Phoenix, and OTP. It finds
commitments across connected accounts, turns them into todos with supporting
evidence, prepares a daily brief, and keeps track of the people involved.

This is an experimental application under active development. Expect rough
edges, changing APIs, and a substantial database setup. Start with a local
instance and accounts you control before connecting personal or work data.

## What's here

- A Phoenix web app and API for todos, people, briefs, and assistant chat.
- Connectors for Google, Slack, GitHub, Linear, Notion, Telegram, and other sources.
- An OTP runtime with durable work, PostgreSQL leases, recovery, and spending controls.
- Native macOS and iOS clients in `apps/companion` and `apps/mobile`.

The web app, API, connectors, and runtime live at the repository root. You can
work on the server without Xcode or either native app.

## Run locally

You need Elixir 1.16.2, Erlang/OTP 26.2.2, Git, and Docker with Compose. The
versions in `mise.toml` match the server's Dockerfile. The database container
provides PostgreSQL 16, pgvector, and the roles required by the migrations.

```sh
git clone https://github.com/argonavis-labs/maraithon.git
cd maraithon

# Optional, if you use mise:
mise install

cp .env.example .env
set -a
source .env
set +a

docker compose up -d --wait db
mix local.hex --force
mix local.rebar --force
PGUSER=maraithon_migrator mix setup
iex -S mix phx.server
```

Mix does not load `.env` automatically. Load it in each new shell before
running the application. The database listens on `127.0.0.1:55432` by default,
so it can coexist with another local PostgreSQL installation. The web app
listens on [localhost:4000](http://localhost:4000).

The included database credentials and development encryption key are local
fixtures. Use separate credentials and encryption keys for any hosted instance.
Migrations run as `maraithon_migrator`; the app runs as `maraithon_runtime`.
The Compose database volume persists when the container stops. Stop it with
`docker compose stop db` when you're done.

### Sign in without an email provider

In the IEx session running the server, create a local sign-in link:

```elixir
email = System.fetch_env!("PRIMARY_ADMIN_EMAIL")
{:ok, %{token: token}} = Maraithon.Accounts.request_magic_link(email)
IO.puts("http://localhost:4000/auth/magic/#{token}")
```

Open the printed link in your browser. It is a short-lived credential for your
local instance; don't share it. Setting `PRIMARY_ADMIN_EMAIL` gives that user
admin access. Normal email sign-in requires your own Postmark configuration.

### Enable integrations deliberately

The local app can start without model or OAuth keys. AI features require a
supported model provider, and each connector needs your own provider credentials.
Add those values to your ignored `.env` file, reload it, and restart the server.
See [connector setup](docs/connectors.md) and `config/runtime.exs` for supported
settings. Model calls and provider services can incur charges.
In production, cost warnings go to `PRIMARY_ADMIN_EMAIL`, or to
`LLM_COST_ALERT_EMAIL` when explicitly set. Email delivery must be configured.

Outbound delegation is off by default. Choose a dedicated assistant mailbox in
Settings before using assistant identity features. Connecting an account does
not itself authorize sending messages.

The distributed exact runtime has a separate database activation procedure.
The local quick start does not activate it or reproduce a production rollout.
Read [the runtime architecture](docs/architecture/durable-agent-runtime.md) and
[the cutover procedure](docs/exact-agent-runtime-cutover.md) before operating it.

## Development

```sh
make build          # Compile Phoenix with warnings treated as errors
mix assets.build    # Build JavaScript and CSS
make build-static   # Digest assets and verify PWA file references
```

The current workflow is manual-first. `make test` and `make verify` are
compile-only compatibility aliases. The existing automated suites remain
available for an explicitly requested testing or hardening pass; they are not
part of the default loop. See [development mode](docs/development-mode.md).

For changes, read [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md).
UI changes also follow [DESIGN.md](DESIGN.md).

## Native clients

- [macOS companion](apps/companion/README.md): local sources and account sync.
- [iOS app](apps/mobile/README.md): todos, people, and assistant chat.

Both use XcodeGen. Generate projects from `project.yml`; generated `.xcodeproj`
files are not committed. Native releases require your own Apple signing setup.

## Deployment and operations

The existing `make deploy` and `make deploy-hardened` commands are maintainer
tools pinned to the original Google Cloud installation. They are not a generic
self-hosting installer. Forks should not run them against that project.

Deployment and TestFlight workflows require an explicit repository-variable
opt-in. A build or contribution does not require cloud credentials. See
[workflow configuration](.github/workflows/README.md).

Useful technical references:

- [Operator CLI](docs/operator-cli.md)
- [Monorepo layout](docs/monorepo.md)
- [Durable runtime](docs/architecture/durable-agent-runtime.md)
- [Database TLS, backups, and restore](docs/operations/database-tls-backup-restore.md)
- [Privacy retention and erasure](docs/operations/privacy-retention-erasure.md)
- [Payload rotation and key retirement](docs/operations/durable-payload-lifecycle.md)

Historical plans and production evidence describe work done on the original
installation. They are not instructions to access that installation, and their
old test commands do not override the current development policy.
Captured production records are withheld from the public tree. A publication
notice at an old evidence path is not proof that a current check has passed.

## Security and licence

See [SECURITY.md](SECURITY.md) for private vulnerability reporting and handling
sensitive data. Do not put credentials, mailbox contents, or personal records
in public issues or pull requests.

Maraithon's original code is available under the [MIT licence](LICENSE).
Third-party assets and UI material retain their own terms; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
