# Todo training dataset

Normal app use now builds the data for a personal todo classifier. The server
preserves what it knew when it made a decision and records what the user did
afterwards. Collection doesn't require another model call.

This collects training evidence. It doesn't train model weights automatically.
The existing outcome learner still turns feedback into per-user relevance
memories that influence the next discovery decision.

## What we keep

- `todo_training_runs`: the exact bounded decision prompt, requested model
  settings, configured provider/model, serving revision, start time, and final
  response provenance. A repaired response includes its final prompt and
  attempt count. Failed and interrupted runs remain visible.
- `todo_training_examples`: every candidate admitted to that model request,
  including skips. Each example contains the candidate evidence, effective
  decision, and saved todo when one exists. The run also preserves the raw
  model response so policy changes aren't confused with model choices.
  Missing decisions are recorded as `unresolved`, never invented negatives.
- `todo_training_feedback`: a sequence of human and automatic actions with
  before/after snapshots, timestamps, source surface, and a link to the most
  recent decision for that todo. Earlier labels survive later corrections.

Decision examples and the corresponding todos commit together. Feedback and
the action that produced it commit together. If either write fails, the
transaction fails and the existing durable ingestion queue can retry. The
model doesn't run inside these database transactions.

The outcome learner uses a frozen input attached to its learning event. Older
events created before this release retain their historical fallback. New
feedback on an older todo is marked `legacy_or_manual_observation`; we don't
pretend to have its original decision prompt.

## Labels

| Action | Meaning for training |
| --- | --- |
| Ignore, Not helpful | Explicit negative relevance |
| Helpful | Explicit positive relevance |
| Completed by the user | Implicit positive, weaker than a relevance review |
| User edit or manual creation | Correction or stated intent; preserve the text |
| Dismiss, reopen, snooze, open detail | Unknown relevance; retain the behaviour |
| Automatic completion or other agent action | Agent observation, not a human label |
| Model skip or no user action | Unknown relevance |

An opened detail is recorded at most once per todo per UTC day. It is not a
list impression. Server data can't establish that the user actually saw every
todo delivered to a device, including offline use.

The `learning_input` event is a frozen input for the existing preference
learner. Exclude it from training labels and action counts. The existing
learner has its own outcome vocabulary; the dataset deliberately keeps
ordinary dismissal ambiguous.

## Export and review

These browser-session endpoints derive the user from authentication. They
never accept another user's ID. Review POSTs retain CSRF protection.

1. Read `GET /api/todo-training/health` for collection counts, recent activity,
   last capture time, and stale pending runs.
2. Download `GET /api/todo-training/export/runs?format=jsonl`, then `examples`
   and `feedback`. Use the first page's `as_of` for every subsequent request
   across all three record types.
3. Follow each response's `next_cursor` until it is null. Pass both `cursor`
   and the same `as_of`. Pages contain at most 16 records. The first JSONL line
   is the manifest; the remaining lines are records. Omit `format=jsonl` for
   ordinary JSON. Keep exported files in private storage, out of Git and logs.
4. Join examples to runs by `run_id`, and feedback to examples by `example_id`.
   Preserve feedback without an example as an observation of an older or
   manually created todo, rather than mixing it into decision-time examples.

To review a candidate, including a skip, POST to
`/api/todo-training/examples/:id/review` with `verdict` (`positive`, `negative`,
or `unknown`), a UUID `request_id`, and an optional `note`. Reusing the same
request ID is idempotent; changing its contents produces a conflict. This is
an API for deliberate review, not a new review screen or an automatic label.

## Preparing a classifier

Use the decision-time prompt and candidate evidence as inputs. Keep model
decisions, saved outputs, and later feedback in separate target/observation
columns. Never feed future feedback into the input for an earlier decision.
An `as_of` export excludes later feedback and hides later run completion.

Resolve the sequence of feedback before assigning one relevance target. For
example, an Ignore followed by a reopen needs review; taking whichever label
is easiest would teach the wrong preference. Train with explicit labels first
and evaluate weaker completion signals separately. Manual creation isn't
proof that discovery missed something unless the source was actually scanned.

Keep each user's data separate by default. A shared model needs a deliberate
data-use decision; collecting personal evidence doesn't authorize pooling it.

For evaluation, use a later time window and keep related records in the same
split. Co-locate rows that share `group_key`, `todo_id`, or `run_id`, including
their transitive connections. The group key prefers source conversation or
thread identity over message identity. Some sources lack a thread ID, so
inspect those fallbacks before trusting a benchmark.

Skips are especially useful for finding false negatives, but remain unlabeled
until reviewed. A promising first model predicts relevance and rank. Keep the
general model responsible for interpreting source material and writing todos
until held-out evidence supports replacing more of the workflow.

## Storage and operations

Payloads use the existing Vault encryption, rotation inventory, user erasure
fences, and account deletion workflow. Logical records and their plaintext
digests are immutable in PostgreSQL; ciphertext can be rotated. Export verifies
the digests. Cross-user run, example, todo, and learning-event associations are
rejected. Deleting a todo also deletes its linked dataset records.

Payloads are capped at 2 MB. An oversized payload becomes an explicit omission
record with its original size and digest. Exclude those records from training;
don't treat missing text as an empty source. Exact bounded prompts normally
fit well below this cap. No automatic short retention window discards the
training history.

The durable `todo_training_health` recurring job runs daily. It reports
content-free aggregate counts and marks pending runs older than two hours as
abandoned. Failed or abandoned runs produce a warning. Check the recurring
schedule and `todo_training_daily_health` logs if collection stops advancing.
A successful health job with zero discovery isn't proof that discovery itself
is running.

This capture boundary covers the shared todo intelligence admission pipeline,
including direct account discovery and Chief of Staff candidates. It doesn't
invent evidence for source items that were never acquired or candidates
filtered before reaching that pipeline.
