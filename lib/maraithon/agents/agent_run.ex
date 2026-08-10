defmodule Maraithon.Agents.AgentRun do
  @moduledoc """
  Durable execution record for one runtime trigger cycle.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Agents.Agent
  alias Maraithon.Agents.AgentPackage
  alias Maraithon.Agents.AgentPackageVersion
  alias Maraithon.Agents.AgentRunStep
  alias Maraithon.DurablePayload
  alias Maraithon.Projects.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @max_trigger_bytes 256_000
  @max_metadata_bytes 128_000
  @payload_bounds [
    max_binary_bytes: 64_000,
    max_depth: 12,
    max_nodes: 10_000,
    max_map_entries: 1_000,
    max_list_items: 2_000
  ]
  @max_budget_count 1_000_000

  schema "agent_runs" do
    field :user_id, :string
    field :behavior, :string
    field :status, :string, default: "running"
    field :trigger_type, :string
    field :trigger, Maraithon.Encrypted.Map, source: :trigger_ciphertext, redact: true
    field :legacy_trigger, :map, source: :trigger, default: %{}, redact: true
    field :resolved_model, :string
    field :intelligence, :string
    field :finish_reason, :string
    field :generation_mode, :string
    field :active_skills, {:array, :string}, default: []
    field :tool_allowlist, {:array, :string}, default: []
    field :budget_snapshot, :map, virtual: true, default: %{}
    field :legacy_budget_snapshot, :map, source: :budget_snapshot, default: %{}, redact: true
    field :budget_llm_calls, :integer
    field :budget_tool_calls, :integer
    field :error, :string
    field :metadata, Maraithon.Encrypted.Map, source: :metadata_ciphertext, redact: true
    field :legacy_metadata, :map, source: :metadata, default: %{}, redact: true
    field :private_payload_encryption_version, :integer
    field :payload_binding_version, :integer
    field :payload_binding_key_tag, :string
    field :payload_binding_mac, :binary, redact: true
    field :private_payload_purged_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :agent, Agent
    belongs_to :agent_package, AgentPackage
    belongs_to :agent_package_version, AgentPackageVersion
    belongs_to :project, Project
    has_many :steps, AgentRunStep, foreign_key: :agent_run_id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:agent_id, :behavior, :status, :started_at]
  @optional_fields [
    :agent_package_id,
    :agent_package_version_id,
    :user_id,
    :project_id,
    :trigger_type,
    :trigger,
    :resolved_model,
    :intelligence,
    :finish_reason,
    :generation_mode,
    :active_skills,
    :tool_allowlist,
    :budget_snapshot,
    :error,
    :metadata,
    :completed_at
  ]

  @doc false
  def payload_binding_spec do
    %{
      table: "agent_runs",
      identity_fields: [:id],
      scope_fields: [:user_id, :agent_id],
      fields: [:trigger, :metadata],
      purge_field: :private_payload_purged_at
    }
  end

  def max_trigger_bytes, do: @max_trigger_bytes
  def max_metadata_bytes, do: @max_metadata_bytes
  def payload_bounds, do: @payload_bounds

  def changeset(run, attrs) do
    attrs = put_new_private_payload_defaults(run, attrs || %{})

    run
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, ["running", "completed", "failed", "cancelled"])
    |> DurablePayload.put_bounded_map(:trigger, @max_trigger_bytes, @payload_bounds)
    |> DurablePayload.put_bounded_map(:metadata, @max_metadata_bytes, @payload_bounds)
    |> validate_budget_snapshot()
    |> promote_budget_facts()
    |> mirror_legacy_budget()
    |> mirror_legacy_payload(:trigger, :legacy_trigger)
    |> mirror_legacy_payload(:metadata, :legacy_metadata)
    |> put_private_payload_encryption_version()
    |> reactivate_private_payload()
    |> DurablePayload.put_binding(payload_binding_spec())
    |> DurablePayload.require_current_mutation()
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:agent_package_id)
    |> foreign_key_constraint(:agent_package_version_id)
    |> foreign_key_constraint(:project_id)
  end

  @doc false
  def hydrate_private_payloads(run, mode \\ DurablePayload.mode!())

  def hydrate_private_payloads(%__MODULE__{} = run, mode) when mode in [:legacy, :exact] do
    :ok = DurablePayload.verify_binding!(run, payload_binding_spec(), mode)
    {trigger, metadata} = read_private_payloads!(run, mode)
    %{run | trigger: trigger, metadata: metadata, budget_snapshot: read_budget!(run, mode)}
  end

  def hydrate_private_payloads(other, _mode), do: other

  @doc false
  def read_private_payloads!(%__MODULE__{private_payload_purged_at: %DateTime{}} = run, _mode) do
    if is_nil(run.trigger) and is_nil(run.metadata) and run.legacy_trigger == %{} and
         run.legacy_metadata == %{} do
      {%{}, %{}}
    else
      raise ArgumentError, "purged AgentRun private payload is corrupt or inconsistent"
    end
  end

  def read_private_payloads!(%__MODULE__{} = run, :legacy) do
    trigger = run.trigger || legacy_map(run.legacy_trigger)
    metadata = run.metadata || legacy_map(run.legacy_metadata)

    if json_map?(trigger) and json_map?(metadata) do
      {trigger, metadata}
    else
      raise ArgumentError, "AgentRun private payload is corrupt or inconsistent"
    end
  end

  def read_private_payloads!(%__MODULE__{} = run, :exact) do
    if run.private_payload_encryption_version == 1 and json_map?(run.trigger) and
         json_map?(run.metadata) and run.legacy_trigger == %{} and run.legacy_metadata == %{} and
         valid_budget_facts?(run) do
      {run.trigger, run.metadata}
    else
      raise ArgumentError, "exact AgentRun private payload is not ciphertext-only"
    end
  end

  defp put_new_private_payload_defaults(%__MODULE__{id: nil}, attrs) when is_map(attrs) do
    attrs
    |> put_attr_default(:trigger, %{})
    |> put_attr_default(:metadata, %{})
    |> put_attr_default(:budget_snapshot, %{"llm_calls" => 0, "tool_calls" => 0})
  end

  defp put_new_private_payload_defaults(_run, attrs), do: attrs

  defp put_attr_default(attrs, field, default) do
    string_field = Atom.to_string(field)

    cond do
      Map.has_key?(attrs, field) or Map.has_key?(attrs, string_field) -> attrs
      Enum.any?(Map.keys(attrs), &is_binary/1) -> Map.put(attrs, string_field, default)
      true -> Map.put(attrs, field, default)
    end
  end

  defp validate_budget_snapshot(changeset) do
    validate_change(changeset, :budget_snapshot, fn :budget_snapshot, budget ->
      if valid_budget_snapshot?(budget),
        do: [],
        else: [budget_snapshot: "must contain only bounded llm_calls and tool_calls counters"]
    end)
  end

  defp promote_budget_facts(changeset) do
    case fetch_change(changeset, :budget_snapshot) do
      {:ok, budget} when is_map(budget) ->
        changeset
        |> put_change(:budget_llm_calls, budget_value(budget, "llm_calls"))
        |> put_change(:budget_tool_calls, budget_value(budget, "tool_calls"))

      _unchanged_or_invalid ->
        changeset
    end
  end

  defp mirror_legacy_budget(changeset) do
    case fetch_change(changeset, :budget_snapshot) do
      {:ok, budget} ->
        put_change(
          changeset,
          :legacy_budget_snapshot,
          if(DurablePayload.legacy_write?(), do: budget, else: %{})
        )

      :error ->
        changeset
    end
  end

  defp read_budget!(run, :legacy) do
    budget =
      if valid_budget_snapshot?(run.legacy_budget_snapshot) do
        %{
          "llm_calls" => budget_value(run.legacy_budget_snapshot, "llm_calls"),
          "tool_calls" => budget_value(run.legacy_budget_snapshot, "tool_calls")
        }
      else
        scalar_budget(run)
      end

    if valid_budget_snapshot?(budget),
      do: budget,
      else: raise(ArgumentError, "AgentRun budget snapshot is corrupt or inconsistent")
  end

  defp read_budget!(run, :exact) do
    if run.legacy_budget_snapshot == %{} and valid_budget_facts?(run),
      do: scalar_budget(run),
      else: raise(ArgumentError, "exact AgentRun budget snapshot is not scalar-only")
  end

  defp scalar_budget(run),
    do: %{"llm_calls" => run.budget_llm_calls, "tool_calls" => run.budget_tool_calls}

  defp valid_budget_snapshot?(budget) when is_map(budget) and not is_struct(budget) do
    allowed = MapSet.new(["llm_calls", :llm_calls, "tool_calls", :tool_calls])

    Enum.all?(Map.keys(budget), &MapSet.member?(allowed, &1)) and
      valid_budget_count?(budget_value(budget, "llm_calls")) and
      valid_budget_count?(budget_value(budget, "tool_calls"))
  end

  defp valid_budget_snapshot?(_budget), do: false

  defp valid_budget_facts?(run) do
    valid_budget_count?(run.budget_llm_calls) and valid_budget_count?(run.budget_tool_calls)
  end

  defp valid_budget_count?(value), do: is_integer(value) and value in 0..@max_budget_count

  defp budget_value(map, key) do
    Map.get(map, key, Map.get(map, String.to_existing_atom(key), 0))
  end

  defp mirror_legacy_payload(changeset, payload_field, legacy_field) do
    case fetch_change(changeset, payload_field) do
      {:ok, payload} ->
        put_change(
          changeset,
          legacy_field,
          if(DurablePayload.legacy_write?(), do: payload, else: %{})
        )

      :error ->
        changeset
    end
  end

  defp put_private_payload_encryption_version(changeset) do
    if Map.has_key?(changeset.changes, :trigger) or Map.has_key?(changeset.changes, :metadata),
      do: put_change(changeset, :private_payload_encryption_version, 1),
      else: changeset
  end

  defp reactivate_private_payload(changeset) do
    if changeset.data.private_payload_purged_at &&
         (Map.has_key?(changeset.changes, :trigger) or Map.has_key?(changeset.changes, :metadata)),
       do: put_change(changeset, :private_payload_purged_at, nil),
       else: changeset
  end

  defp legacy_map(value) when is_map(value) and not is_struct(value), do: value
  defp legacy_map(_value), do: nil
  defp json_map?(value), do: is_map(value) and not is_struct(value)
end
