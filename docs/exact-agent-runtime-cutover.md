# Exact Agent runtime production cutover

`EXACT_AGENT_RUNTIME_ENABLED` defaults to `false`. Treat it as a production
safety interlock, not as evidence that another process or revision is absent.
Do not enable it in an ordinary rolling deployment.

The first exact-runtime rollout is a mandatory **two-deploy, non-rolling
cutover**:

1. Deploy the schema and exact-runtime-capable code with
   `EXACT_AGENT_RUNTIME_ENABLED=false`. Verify the new revision leaves
   `Maraithon.Runtime.BootGate` closed and does not claim, recover, start, or
   bootstrap exact Agents.
2. Outside the new runtime, stop every legacy Agent producer and scheduler.
   Stop and remove **every** old application revision and worker revision; do
   not leave a rolling overlap.
3. Prove fleet absence using the platform's revision/instance inventory and
   shutdown evidence. `BootGate`, an Erlang `Registry`, PID lookup,
   `Node.list/0`, and the lifecycle-operation table are process-local or
   database state and **do not prove** that an old fleet is absent.
4. Prove durable quiescence directly: no live Agent runtime lease, no
   processing Agent directive, no running Agent run, no requested run step,
   and no pending/claimed/cancelling Effect for the cutover set. Investigate
   and reconcile each non-quiescent row; do not broadly delete it.
5. Make a second, non-rolling deployment with
   `EXACT_AGENT_RUNTIME_ENABLED=true`. Only this revision may bootstrap and
   claim exact Agents. Verify fresh owner tokens and ready-last activation.

If any old revision or unresolved durable work appears while enabling, disable
the gate and stop the exact revision. Drain and prove absence again before a
new enable attempt. Never infer a safe overlap from a durable epoch alone; an
epoch may supplement, but cannot replace, external fleet-drain proof.

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
