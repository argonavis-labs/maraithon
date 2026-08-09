# Chief production-lineage foundation (feature-dark)

This slice adds durable data contracts only. It does **not** route webhooks,
enqueue or claim directives, run the Chief behavior, project Todos, change Todo
or `SurfaceQuality` behavior, advance a live cursor from an existing runtime
path, or acknowledge logical work.

## Durable boundaries

- `runtime_ingress_receipts` permanently deduplicates one exact
  user/Agent/connected-account/provider event. Admission fails closed unless the
  persisted account is connected, the Agent is enabled with an active same-user
  isolation binding, and both the Agent grant and binding scope explicitly list
  the account under `provider => %{"account_ids" => [canonical_account_key]}`.
  The canonical provider account identity is the canonical, nonempty persisted
  `external_account_id`. Missing or invalid persisted identity fails closed; a
  caller-supplied key is verification input only, never identity authority.
  Rejected transport content is not stored. Admitted payloads are canonical
  bounded JSON, and credential or
  provider-exception keys are rejected.
- `chief_acquisition_runs` owns contiguous immutable pages and source-envelope
  associations. A run is sealed `complete` only from its persisted terminal
  page/count/manifest proof. A sealed `incomplete` run retains continuation
  proof but is never admitted to semantics or cursor advancement.
- Source envelopes are immutable provider item revisions. Each semantic
  occurrence has an immutable key scoped by its immutable acquisition key plus
  its sorted source-envelope evidence. The same evidence observed by a later
  acquisition is therefore a distinct occurrence; there is no UUID fallback.
- Projection receipts are immutable and point to exactly one existing Todo or
  immutable Chief decision. The feature-dark API does not create or update a
  Todo; a later coordinator must run the existing quality/family rules first.
- An Agent work result is inserted `provisional` inside the terminal database
  transaction and must become `committed` before that transaction can commit.
  Deferred database proof binds it to the exact directive claim generation and
  token, the exact terminal AgentRun, one or more sealed acquisitions, every
  semantic projection, and each required cursor compare-and-set receipt.

## Deferred atomic Runtime wiring

No nullable inverse linkage column was added to `AgentRun`, `AgentDirective`, or
`Snapshot`; those models are concurrently owned by the core Runtime integration.
`AgentWorkResults`, `Projections`, and `SourceCursorAdvancements` expose
caller-transaction/Multi primitives instead. The later terminal coordinator
must own one transaction that:

1. fences and rechecks the exact live directive claim and consent;
2. inserts the provisional work result and acquisition links;
3. writes Todo/Decision projection receipts;
4. compare-and-set advances all source cursors and writes immutable receipts;
5. terminalizes the AgentRun and persists/links its idle Snapshot;
6. terminalizes the exact Directive claim; and
7. marks the work result committed.

The deferred constraints reject a partial commit. Until that coordinator and an
atomic ingress-receipt + directive-enqueue boundary are wired, every new API is
feature-dark and no existing runtime path calls it.
