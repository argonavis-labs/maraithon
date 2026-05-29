# Chief of Staff Dogfood Telemetry

The 30-day Chief of Staff dogfood run uses runtime incidents plus a daily
Telegram digest to prove the agent can run unattended, recover from crashes, and
leave an audit trail when it cannot.

## Runtime Settings

| Environment variable | Default | Meaning |
| --- | --- | --- |
| `AGENT_WATCHER_POLL_INTERVAL_MS` | `2000` | How often the watcher reconciles live agent processes with the registry. |
| `AGENT_CRASH_LOOP_MAX` | `3` | Number of crashes in the crash-loop window before the watcher stops trying to re-resume the agent. |
| `AGENT_CRASH_LOOP_WINDOW_MS` | `600000` | Rolling crash-loop window, in milliseconds. |
| `AGENT_RERESUME_BACKOFFS` | `5000,15000,30000` | Comma-separated recovery delays after agent crashes, in milliseconds. |
| `DOGFOOD_USER_ID` | `PRIMARY_ADMIN_EMAIL` | User whose Telegram connection receives the daily dogfood digest. |
| `DOGFOOD_DIGEST_HOUR` | `7` | Local hour for the daily digest. |
| `DOGFOOD_DIGEST_MINUTE` | `30` | Local minute for the daily digest. |
| `DOGFOOD_DIGEST_TIMEZONE` | `America/Toronto` | Human-readable timezone label shown in the digest. |
| `DOGFOOD_DIGEST_TIMEZONE_OFFSET_HOURS` | `-4` | Fixed UTC offset used to schedule the digest. Update this if the run crosses daylight saving time. |

## Digest Contract

The digest should be useful without reading logs. It reports the trailing
24-hour uptime window, incident counts, each recent agent crash with its recovery
outcome, current backlog counts, the latest boot baseline, and the current
health snapshot.

Crash outcomes are derived from the next incident for the same agent:

- `recovered`: the crash was followed by `agent_resumed` with
  `resume_trigger=targeted_reresume`.
- `not recovered`: the crash was followed by `agent_stopped_unexpectedly`.
- `recovery pending`: no recovery or stop incident has been recorded yet.

Before starting a production dogfood window, run a manual delivery smoke test and
confirm the destination user has a connected Telegram account.
