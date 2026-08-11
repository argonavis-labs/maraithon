defmodule Maraithon.Runtime.AgentLocalDownWitness do
  @moduledoc false

  @enforce_keys [
    :watcher_pid,
    :monitor_ref,
    :pid,
    :agent_id,
    :lease_token,
    :monitor_started_at,
    :down_reason,
    :capability_id,
    :capability
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          watcher_pid: pid(),
          monitor_ref: reference(),
          pid: pid(),
          agent_id: String.t(),
          lease_token: String.t(),
          monitor_started_at: DateTime.t(),
          down_reason: term(),
          capability_id: reference(),
          capability: (term() -> term())
        }
end
