# Exact Agent runtime production cutover

`EXACT_AGENT_RUNTIME_ENABLED` defaults to `false`. Treat it as a production
safety interlock, not as evidence that another process or revision is absent.
Do not enable it in an ordinary rolling deployment.

The first exact-runtime rollout is a mandatory **two-deploy, non-rolling
cutover**:

1. Deploy the additive schema and dual-write-capable code with
   `EXACT_AGENT_RUNTIME_ENABLED=false`. While protocol mode is `legacy`, new
   writers must retain the original legacy JSON **and** ciphertext so old
   readers remain compatible. Verify the new revision leaves
   `Maraithon.Runtime.BootGate` closed and does not claim, recover, start, or
   bootstrap exact Agents.
2. Outside the new runtime, stop every legacy Agent producer and scheduler.
   Stop and remove **every** old application revision and worker revision; do
   not leave a rolling overlap.
3. Prove fleet absence using the platform's revision/instance inventory and
   shutdown evidence. `BootGate`, an Erlang `Registry`, PID lookup,
   `Node.list/0`, and the lifecycle-operation table are process-local or
   database state and **do not prove** that an old fleet is absent.
4. Only after that external fleet-absence proof, contract the dual-written
   payloads by running the resumable encryption backfill until it reports zero
   remaining Effect and Directive rows:

       mix maraithon.payloads.backfill_effects --batch-size 100

   The task loads application configuration but starts only Ecto SQL,
   `Maraithon.Vault`, and `Maraithon.Repo`; it does **not** start
   `Maraithon.Application`, Runtime.Supervisor, or a producer, so the stopped
   fleet proof remains valid. It replaces legacy JSON with a redacted
   projection only after ciphertext is durable. Ciphertext/decryption failures
   stop the task and never fall back silently. Do not run this contracting step
   while any legacy reader can still claim work.
5. Prove durable quiescence directly: no live Agent runtime lease, no
   processing Agent directive, no running Agent run, no requested run step,
   and no pending/claimed/cancelling Effect for the cutover set. Investigate
   and reconcile each non-quiescent row; do not broadly delete it.
6. While the application fleet remains stopped, irreversibly activate exact
   Effect execution with the repository-only operator task:

       mix maraithon.effects.activate_generation_fenced \
         --confirm NON_ROLLING_FLEET_DRAINED

   The task starts only Ecto migration dependencies and `Maraithon.Repo`; it
   must not boot `Maraithon.Application`, Runtime.Supervisor, or any producer.
   Its database trigger repeats the payload-encryption, lease, durable-work,
   recorded-migration, and exact-catalog gates under the canonical locks. A
   lock timeout is a retryable refusal.
7. Make a second, non-rolling deployment with
   `EXACT_AGENT_RUNTIME_ENABLED=true`. Only this revision may bootstrap and
   claim exact Agents. Verify fresh owner tokens and ready-last activation.

If any old revision or unresolved durable work appears while enabling, disable
the gate and stop the exact revision. Drain and prove absence again before a
new enable attempt. Never infer a safe overlap from a durable epoch alone; an
epoch may supplement, but cannot replace, external fleet-drain proof.


## Why activation is not a migration

Migrations `20260810132102`, `20260810132103`, and `20260810140000`
expand/index the Effect protocol and add encrypted Directive storage. They
deliberately leave the singleton mode as `legacy`. There is no
`20260810132104_activate_generation_fenced_effect_execution.exs`: an ordinary
migration can run during a rolling deploy and cannot prove that legacy
revisions have stopped. Activation is manual-only, one-way, and operator
confirmed through the task above. Re-running the task is idempotent only while
all required migration records,
the exact index definitions, the named constraint definitions, and the trigger
function fingerprints remain healthy; it never downgrades the protocol. The
fingerprints live in the immutable `effect_execution_protocol_manifests`
singleton and make a same-name `CHECK (TRUE)` or no-op replacement function a
closed readiness failure rather than acceptable catalog presence.

## Required database-role boundary

The trigger is the safety boundary, not the human-authorization boundary. Before
production activation, use separate runtime and migration/operator PostgreSQL
roles:

- the runtime role may perform the reviewed application DML but must not own the
  protocol tables/functions or exact indexes;
- revoke table-wide `UPDATE`, `DELETE`, and `TRUNCATE` authority on
  `public.effect_execution_protocols` from the runtime role, then grant only
  `SELECT` plus column-level `UPDATE (updated_at)`. PostgreSQL requires some
  update privilege for the runtime's locking `SELECT ... FOR SHARE`; the
  harmless audit timestamp column supplies that lock privilege without granting
  authority over `mode`, `activated_at`, or `activation_epoch`;
- grant the runtime role `SELECT` but not `INSERT`, `UPDATE`, `DELETE`, or
  `TRUNCATE` on `public.effect_termination_attestations`;
- do not grant the runtime role schema/function/index DDL;
- run migrations and the one-time activation task with the separately scoped
  operator role, then return the application to runtime credentials;
- give a separately authenticated incident-operator role the reviewed runtime
  DML plus `INSERT` on `public.effect_termination_attestations`. Do not give the
  ordinary application role that insert authority.

A representative grant shape (replace role names; preserve the application's
separately reviewed DML grants on ordinary tables) is:

    REVOKE INSERT, UPDATE, DELETE, TRUNCATE
      ON public.effect_execution_protocols FROM maraithon_runtime;
    GRANT SELECT, UPDATE (updated_at)
      ON public.effect_execution_protocols TO maraithon_runtime;
    REVOKE INSERT, UPDATE, DELETE, TRUNCATE
      ON public.effect_execution_protocol_manifests,
         public.effect_termination_attestations FROM maraithon_runtime;
    GRANT SELECT
      ON public.effect_execution_protocol_manifests,
         public.effect_termination_attestations TO maraithon_runtime;
    GRANT SELECT, INSERT
      ON public.effect_termination_attestations TO maraithon_incident_operator;

The incident role also needs the reviewed runtime reconciliation DML and the
same protocol-row `SELECT, UPDATE (updated_at)` lock privilege. It must not own
these tables, functions, triggers, or exact indexes.

An owner can set custom PostgreSQL GUCs, so the confirmation string alone cannot
provide operator authorization. The release is not approved until the role
split is verified from production grants. Keep both database credentials out of
the repository and deployment logs.

## Unfenced legacy-process marker

A lifecycle request that conservatively observes a local Registry entry without
an exact UUID owner token persists `requires_external_drain=true`. Registry
**presence** may block unsafe finalization, but Registry absence is never used
as fleet-absence proof. `WakeCoordinator` deliberately retains that marker.

After the non-rolling drain in steps 2–4 has been proven externally, the release
operator must submit an explicit evidence envelope through
`AgentLifecycleOperations.confirm_external_drain/3`. The envelope requires
`non_rolling: true`, a unique `proof_id`, `confirmed_by`, and the drained
`legacy_revision`. Only its SHA-256 digest and the PostgreSQL confirmation time
are persisted. A different retry conflicts; there is no automatic or
Registry-derived confirmation. Ordinary exact-owner operations do not require
this bridge confirmation and remain crash-reconcilable.

## Permanently unreachable exact Effect tasks

A node-down event, lease expiry, RPC timeout, Registry miss, or a missing task
name is not physical-termination proof. Cancellation therefore leaves the exact
claim in `cancelling/requested` until the coupled live Task.Supervisor returns a
monitored termination/absence proof. The cancellation claim token and physical
`owner_node` / `supervisor_id` / `task_id` identity remain immutable while it is
unresolved.

When the owner can never return, an incident operator may provide external,
task-bound proof. First verify platform evidence that the named VM/container and
BEAM Task.Supervisor incarnation have been destroyed and cannot resume. Record a
non-secret evidence reference (not raw logs or credentials) with the scoped
incident role:

    mix maraithon.effects.attest_terminated       --effect-id UUID       --claim-token UUID       --owner-node NAME       --supervisor-id UUID       --task-id UUID       --evidence-id INCIDENT-OR-PLATFORM-REFERENCE       --attested-by OPERATOR-ID       --confirm PHYSICAL_TASK_TERMINATED

The database trigger accepts an insert only while all five durable identity
fields still match one exact `cancelling/requested` row. The immutable record
stores the evidence reference, its SHA-256 digest, actor, and database time.
Reconciliation then settles the Effect as
`failed/effect_outcome_ambiguous`; it does **not** invent provider success or
failure. Wrong or stale identities fail closed. Keep the incident record and
external evidence according to the security retention policy.
