defmodule Maraithon.Behaviors.Behavior do
  @moduledoc """
  Behaviour specification for agent behaviors.
  """

  @type state :: any()
  @type context :: %{
          agent_id: String.t(),
          user_id: String.t() | nil,
          timestamp: DateTime.t(),
          budget: map(),
          recent_events: [map()],
          user_memory: map(),
          last_message: String.t() | nil,
          last_message_metadata: map(),
          last_message_id: String.t() | nil,
          trigger: map() | nil,
          event: map() | nil,
          source_bundle: map() | nil,
          assistant_cycle_id: String.t() | nil,
          assistant_fetch_telemetry: map() | nil,
          assistant_origin_skill_id: String.t() | nil,
          assistant_origin_skill_rank: pos_integer() | nil
        }

  @type effect ::
          {:llm_call, params :: map()}
          | {:tool_call, tool :: String.t(), args :: map()}

  @type wakeup_schedule ::
          {:relative, milliseconds :: pos_integer()}
          | {:absolute, DateTime.t()}
          | :none

  @doc """
  Initialize behavior state from config.
  """
  @callback init(config :: map()) :: state()

  @doc """
  Handle a wakeup event.

  Returns:
    - `{:effect, effect, state}` - Request an effect (LLM call, tool call)
    - `{:emit, {event_type, payload}, state}` - Emit an event and return to idle
    - `{:continue, state}` - Continue working (re-enter handle_wakeup)
    - `{:idle, state}` - Return to idle state
  """
  @callback handle_wakeup(state(), context()) ::
              {:effect, effect(), state()}
              | {:emit, {atom(), map()}, state()}
              | {:continue, state()}
              | {:idle, state()}

  @doc """
  Handle the result of an effect.

  Returns same as handle_wakeup.
  """
  @callback handle_effect_result({:llm_call | :tool_call, result :: any()}, state(), context()) ::
              {:emit, {atom(), map()}, state()}
              | {:effect, effect(), state()}
              | {:continue, state()}
              | {:idle, state()}

  @callback handle_effect_error(:llm_call | :tool_call, reason :: any(), state(), context()) ::
              {:emit, {atom(), map()}, state()}
              | {:effect, effect(), state()}
              | {:continue, state()}
              | {:idle, state()}

  @doc """
  Determine when to schedule the next wakeup.
  """
  @callback next_wakeup(state()) :: wakeup_schedule()

  @doc """
  Current version of the behavior's snapshot-state contract (SPEC 08).

  Stored alongside every checkpoint snapshot and compared at restore time.
  A behavior that doesn't implement this is treated as version `0`.
  """
  @callback schema_version() :: non_neg_integer()

  @doc """
  Migrate a snapshot's `behavior_state` written under an older schema version
  (SPEC 08). Called at restore time, before the generic default-merge, only
  when `stored_version < schema_version()`. Must be pure and idempotent. An
  exception here is rescued by the runtime: migration is skipped and the raw
  snapshot state is restored instead.
  """
  @callback migrate_state(stored_version :: non_neg_integer(), state(), config :: map()) ::
              state()

  @doc """
  Reconcile a restored (default-merged, possibly migrated) state against the
  CURRENT agent config (SPEC 08). Called only at restore time — never
  per-wakeup — so config-derived state (e.g. an enabled-skill list) tracks
  the live config instead of staying frozen at snapshot time. Must be pure
  and idempotent. An exception here is rescued by the runtime: reconciliation
  is skipped and the merged state is restored unreconciled.
  """
  @callback reconcile_restored_state(state(), config :: map()) :: state()

  @doc """
  Returns the state to persist in a checkpoint snapshot.

  Behaviors that hold large transient working data (fetched source bundles,
  raw provider payloads) strip it here so checkpoints stay within the
  snapshot size cap; restored state must tolerate those fields being empty.
  """
  @callback snapshot_state(state()) :: state()

  @optional_callbacks handle_effect_error: 4,
                      schema_version: 0,
                      migrate_state: 3,
                      reconcile_restored_state: 2,
                      snapshot_state: 1
end
