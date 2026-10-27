# Maraithon

Maraithon is an AI Chief of Staff for your life and work. It finds commitments
across connected accounts, turns them into todos with supporting evidence,
prepares a daily brief, and keeps track of the people involved.

I'm building it around a few useful questions: what do I owe this person, who
am I waiting on, and what do I need to know before this meeting?

The work is already there, spread across email, calendars, messages, and the
other tools you use. Maraithon brings it together and keeps following it as
things change. A new reply can change a priority, supply the missing context,
or show that something is already done.

The unit of value is a todo you can trust. You should be able to see where it
came from, why it matters, and what would finish it. The daily brief should
help you start the day knowing what needs your attention. People context
should help you arrive prepared and follow up when it matters.

This is experimental software under active development. Expect rough edges,
changing APIs, and a substantial database setup. Start locally with accounts
you control.

## Why Erlang and OTP

An assistant has work that outlives any one request. It might wait hours for a
reply, pick up a conversation tomorrow, or recover in the middle of preparing
your morning brief. Providers time out. Connections disappear. Processes
crash. The application still needs to know what it was doing and what it can
safely do next.

That is why Maraithon uses Elixir on the BEAM, Erlang's virtual machine, and
OTP, Erlang's libraries and design principles for building concurrent,
fault-tolerant applications. The server code is Elixir. The approach to
running it comes from Erlang and OTP.

### Give agents an explicit lifecycle

A long-running agent has state, a mailbox, and work in progress. It needs to
respond to new information while keeping track of what it already owns.

Maraithon's resident agents use OTP's `gen_statem` through Elixir's
`GenStateMachine` library. Their states include `recovering`, `idle`,
`working`, and `waiting_effect`. Making those states explicit helps us reason
about what a new message, a timeout, or a failed action means at each point.

The model can help decide what to do. The runtime tracks the execution: who
owns the work, what is allowed to run, what is waiting, and what actually
finished. That separation makes the system easier to understand when
something goes wrong.

### Make failure part of the design

OTP gives us isolated processes, supervisors, and monitors. We can organise
work into processes with clear responsibilities, observe when they stop, and
build a recovery path around that information.

In Maraithon, slow model and provider calls run outside the coordination
loops. Concurrency, timeouts, and retries have limits. A repeated crash trips
a durable restart guard so the same broken work cannot restart forever.

Recovery should get useful work moving again. A healthy process is only part
of that. The brief still needs to arrive, the todo still needs to reflect the
latest evidence, and an unresolved failure needs to be visible.

### Keep a durable record of authority and outcomes

A supervisor can restart a process. It cannot tell you whether an email
provider accepted a message just before the connection dropped.

Maraithon uses PostgreSQL for durable intent, checkpoints, ownership, and
outcomes. In the exact runtime, time-limited leases identify the current owner
of a piece of work. Database checks fence out a worker whose authority has
expired or been replaced. Recovery restores a bounded checkpoint and
reconciles the durable work that remains.

An external action with an unknown outcome needs reconciliation before it is
safe to repeat. Restarting its process does not settle that question. This is
why the runtime records uncertainty as well as success and failure.

OTP gives us the tools to keep execution responsive and supervised.
PostgreSQL gives us the durable facts needed to recover safely. Both have a
clear job.

### Keep it understandable

The aim is a small runtime with clear responsibilities. An extra coordination
layer needs to solve a concrete failure case that the existing machinery
cannot handle. We should be able to follow a piece of work from its source,
through a decision and an action, to the evidence that it finished.

That is the philosophy behind the architecture: build an assistant that can
keep paying attention, recover from routine failures, and explain its work.

For the implementation, start with the [agent state machine](lib/maraithon/runtime/agent.ex),
[supervision tree](lib/maraithon/runtime/supervisor.ex), and
[durable runtime design](docs/architecture/durable-agent-runtime.md).
The exact runtime requires a separate database activation procedure, described
below. Starting the local app does not activate those protocols.

## What's here

- A Phoenix web app and API for todos, people, briefs, and assistant chat.
- Connectors for Google, Slack, GitHub, Linear, Notion, Telegram, and other sources.
- An OTP runtime for long-running agents, durable work, recovery, and spending controls.
- A [macOS companion](apps/companion/README.md) for local sources and account sync.
- An [iOS app](apps/mobile/README.md) for todos, people, and assistant chat.

The server, connectors, runtime, migrations, and Dockerfile live at the
repository root. The native apps live in `apps/companion` and `apps/mobile`.
You can work on the server without Xcode or either native app.

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

Open [localhost:4000](http://localhost:4000). Mix does not load `.env` for you,
so load it in each new shell before running the app.

The database listens on `127.0.0.1:55432`, which lets it coexist with another
local PostgreSQL installation. Migrations run as `maraithon_migrator`; the app
runs as `maraithon_runtime`.

The included database credentials and development encryption key are public
local fixtures. Use your own credentials and encryption keys for a hosted
instance. The Compose volume keeps your local data when the container stops.
Run `docker compose stop db` when you're done.

### Sign in without an email provider

In the IEx session running the server, create a local sign-in link:

```elixir
email = System.fetch_env!("PRIMARY_ADMIN_EMAIL")
{:ok, %{token: token}} = Maraithon.Accounts.request_magic_link(email)
IO.puts("http://localhost:4000/auth/magic/#{token}")
```

Open the printed link in your browser. It is a short-lived credential for
that local instance, so keep it to yourself. `PRIMARY_ADMIN_EMAIL` gives that
user admin access. For normal email sign-in, configure your own Postmark account.

### Add models and connected accounts

You can start the local app without model or OAuth keys. To use AI features,
configure a supported model provider. Each connector also needs your own
provider credentials. Put them in the ignored `.env` file, reload it, and
restart the app. See [connector setup](docs/connectors.md) and
[`config/runtime.exs`](config/runtime.exs) for the settings.

Model calls and provider services can cost money. In production, cost warnings
go to `PRIMARY_ADMIN_EMAIL`, or to `LLM_COST_ALERT_EMAIL` if you set it. Those
warnings require email delivery to be configured.

Outbound delegation is off by default. Choose a dedicated assistant mailbox
in Settings before using assistant identity features. Connecting an account
is not permission to send messages from it.

### Activate the runtime deliberately

The distributed exact runtime has its own database activation procedure. The
local quick start does not perform it or reproduce a production rollout.
Read the [runtime design](docs/architecture/durable-agent-runtime.md) and
[cutover procedure](docs/exact-agent-runtime-cutover.md) before operating it.

## Development

Keep the loop small. Build the part you're changing, inspect the result, and
follow the work through the app.

```sh
make build          # Compile Phoenix with warnings treated as errors
mix assets.build    # Build JavaScript and CSS
make build-static   # Digest assets and verify PWA file references
```

The current workflow is manual-first. `make test` and `make verify` are
compile-only compatibility aliases. Their names do not mean tests ran. The
existing automated suites stay intact and are available when testing or
hardening is explicitly requested. See [development mode](docs/development-mode.md)
for the current policy.

Read [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md) before making
a change. UI work also follows [DESIGN.md](DESIGN.md). A useful contribution
makes a todo more trustworthy, improves preparation, or helps the application
follow through reliably.

## Native clients

The [macOS companion](apps/companion/README.md) and [iOS app](apps/mobile/README.md)
have their own setup instructions. Both use XcodeGen: edit `project.yml` and
generate the project from it. Generated `.xcodeproj` files are not committed.
Native releases need your own Apple signing setup.

## Deployment and operations

The checked-in `make deploy` and `make deploy-hardened` commands target the
original maintainer's Google Cloud installation. A fork needs its own hosting
configuration before using that tooling.

Deployment and TestFlight workflows require an explicit repository-variable
opt-in. You don't need cloud credentials to build the app or contribute. The
[workflow guide](.github/workflows/README.md) explains those controls.

For operating your own instance, these are the places to start:

- [Operator CLI](docs/operator-cli.md)
- [Monorepo layout](docs/monorepo.md)
- [Durable runtime](docs/architecture/durable-agent-runtime.md)
- [Database TLS, backups, and restore](docs/operations/database-tls-backup-restore.md)
- [Privacy retention and erasure](docs/operations/privacy-retention-erasure.md)
- [Payload rotation and key retirement](docs/operations/durable-payload-lifecycle.md)

Historical plans describe work on the original installation. They do not grant
access to it, and their old test commands do not override the current
development policy. Captured production records are withheld from the public
tree. A notice at an old evidence path tells you the record was withheld; it
does not prove that a current check passed.

## Security and licence

Maraithon handles personal context. Keep credentials, mailbox contents, and
personal records out of public issues and pull requests. Use the private
reporting process in [SECURITY.md](SECURITY.md) for vulnerabilities.

The project's original code is available under the [MIT licence](LICENSE).
Third-party assets and UI material retain their own terms, listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
