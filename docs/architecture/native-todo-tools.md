# Native tools in the todo workspace

September 8, 2026

Linked todo conversations now use provider-native tool calls through Maraithon's existing assistant harness when the configured provider is OpenRouter. This is the next integration selected by the [framework comparison](agent-framework-slice.md).

The model receives the same focused action catalog as before. It returns function calls with IDs, the existing Runner executes them, and the next model turn receives each actual result paired with its call ID. A reserved `maraithon_finish` function carries the final reply and its response class. It never executes an action.

## Ownership and recovery

PostgreSQL leases, OTP process ownership, tool permissions, approved-action execution, repeat detection and the run deadline remain authoritative. This adds a protocol adapter, not a second agent runtime. Native calls must match the current catalog exactly. Unknown names execute nothing and use the existing bounded repair path.

Provider continuation stays in the current run's process memory. Complete call/result exchanges, including opaque provider reasoning details, are retained within a 40 KB budget. Older exchanges are dropped whole when necessary; the existing compact, durable tool history remains available as execution evidence. Provider reasoning is excluded from persisted run requests and responses and from the public progress stream.

Requests remain bounded to 120 KB by the harness and 128 KB by the provider boundary. The transport allows up to 128 tool definitions because the current focused todo catalog contains 64 actions before the final-response function and optional model escalation. That changes no tool permissions or per-step execution allowance: at most three calls can execute in one step.

## Client behavior

Web, Mac and iPhone use the same server harness. The existing shared progress stream continues to show run and tool progress. The native exchange uses a bounded complete provider response; this slice does not add incremental streaming of native function arguments or reply tokens.

Other conversations, proactive plans and providers retain their existing JSON contract. Set `MARAITHON_TODO_TOOL_PROTOCOL=json` and deploy a new revision to roll linked todos back to the JSON contract. No production dependency, database or hosted service was added.

## Validation

The production Elixir 1.16.2 / OTP 26.2.2 build compiled with warnings treated as errors. A bounded manual exchange used the actual harness and OpenRouter adapter against the existing synthetic meeting fixture. It requested `get_meeting`, `get_people` and `get_notes`, then returned a grounded brief on the second model turn. The second request contained the assistant's native call message followed by three paired tool-result messages. Request sizes were 51,153 and 53,916 bytes in that fixture. No production records or external actions were involved.

A separate inspection of the actual focused todo catalog found 65 native functions, including the final response, in an 80,717-byte request. The request passed the provider budget. No application test suite was added or run, following the repository's manual-first policy.

The corrected native-tool release reached Cloud Run revision `maraithon-00275-89n`, image `dev-6f3874d1fa94-20260908191627-1`. A live request from the installed Mac app read the next day's calendar and prepared “Coordinate availability with Christina” for September 9, 11:30–11:45 AM in America/Toronto. The todo stayed open. The action card showed the missing Google calendar-write permission and did not book an event.

That live check exposed a broad legacy shortcut that interpreted a request containing “tomorrow” as a snooze. The todo was restored to open, and conversational requests now pass through the harness unless the whole message is a supported explicit mutation command. A boolean-guard error in that correction briefly returned a service error. Traffic was restored to the prior serving revision while the corrected patch deployed. Retrying the same pending client message then completed successfully.

The following [owned-workflow slice](owned-todo-workflows.md) makes the meeting itself the outcome and keeps supporting actions from closing it.
