# Chief of Staff Fresh Start and Intelligent Source Monitoring

Status: In Progress
Purpose: Reset Kent's stale operator state while preserving connectors, then make the AI Chief of Staff the single owner for fresh Gmail, Slack, Calendar, and Telegram follow-through.

## 1. Product Contract

Kent should experience one Chief of Staff, delivered primarily through Telegram, that continuously watches the connected work surfaces and only interrupts when there is a high-confidence reason.

The agent must monitor:

- Gmail accounts connected under `kent@runner.now`, especially `kent@voteagora.com`
- Slack workspaces connected under `kent@runner.now`
- Calendar context for meetings and follow-up
- Telegram as the command, feedback, and notification surface

## 2. Fresh Start Scope

Delete stale operator artifacts for Kent:

- todos
- insights
- insight deliveries
- briefs
- Telegram push receipts

Preserve:

- users
- connected accounts
- OAuth tokens
- Telegram link
- running Chief of Staff agent
- preference rules
- user memory

Legacy standalone agents that duplicate Chief of Staff behavior should be stopped or removed after the Chief of Staff is verified healthy.

## 3. Source Monitoring Design

The Chief of Staff should use one shared acquisition cycle for connected sources, then route normalized source state through internal skills.

| Source | Role | Freshness rule |
|---|---|---|
| Gmail | reply debt, commitments, direct asks, meeting artifacts | follow-through consumes only the follow-up window; travel may use longer history |
| Slack | DM reply debt, channel commitments, unresolved owners | monitor via bot/user tokens and workspace events when available |
| Calendar | meeting prep and post-meeting follow-up | look backward for recent meetings and forward for upcoming meetings |
| Telegram | delivery, commands, feedback, preference learning | never required for source acquisition, but required for operator interaction |

## 4. Intelligence and Tool Calling

The assistant should combine deterministic source parsing with LLM/tool calls:

- deterministic filters for recency, sender class, labels, thread state, and prior dismissal
- LLM classification only after the candidate clears the cheap filters
- tools for fetching full Gmail threads, Slack thread history, and calendar details when a candidate needs evidence
- Telegram feedback tools to convert `Not Interested` / `Not Helpful` into durable preferences

MCP tools should be added as provider-facing tool boundaries where they reduce custom connector code or expose richer thread/search operations. Gmail, Slack, and Calendar are the priority MCP candidates.

## 5. Attention Rules

An item becomes `act_now` only when all are true:

- new or recently changed source evidence exists
- Kent is plausibly the owner of the next action
- the ask, promise, blocker, or deadline is explicit
- no reply/completion/ownership-transfer evidence closes the loop
- the agent can explain `why now` from source evidence

Otherwise important items should become `monitor` or stay silent.

## 6. Operational Acceptance

- Kent's Google, Slack, and Telegram connections are healthy.
- Stale persisted state is cleared without disconnecting accounts.
- The standalone Gmail advisor no longer competes with the AI Chief of Staff.
- The Chief of Staff rebuilds from fresh source state only.
- Telegram can be used to trigger refreshes and capture feedback.
