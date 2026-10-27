defmodule Maraithon.Delegations.Binding do
  @moduledoc "Delegation references inside existing authenticated payloads; legacy MAC contracts stay unchanged."
  import Ecto.Changeset

  @key "_maraithon_delegation"
  @action_columns ~w(id user_id run_id conversation_id chat_id surface authorization_kind delegation_id delegation_turn_id grant_version)a
  @run_columns ~w(id user_id conversation_id chat_id surface trigger_type)a

  def key, do: @key
  def columns(:action), do: @action_columns
  def columns(:run), do: @run_columns

  def legacy_write?(changeset),
    do:
      get_field(changeset, :surface) != "delegation" and Maraithon.DurablePayload.legacy_write?()

  def mode(%{surface: "delegation"}, _), do: :exact
  def mode(_, mode), do: mode

  def context(d, turn, grant, run_id) do
    %{
      "version" => 1,
      "delegation_id" => d.id,
      "turn_id" => turn.id,
      "user_id" => d.user_id,
      "run_id" => run_id,
      "grant_version" => grant.version,
      "source_revision" => d.source_revision,
      "workflow_revision" => d.workflow_revision,
      "scope_hash" => grant.data["scope_hash"]
    }
  end

  def validate_changeset(changeset, kind) do
    row = apply_changes(changeset)
    payload_field = if kind == :action, do: :payload, else: :prompt_snapshot

    if matches?(kind, row, Map.get(row, payload_field)),
      do: changeset,
      else: add_error(changeset, payload_field, "does not match its delegation authority")
  end

  def verify!(kind, row, payload) do
    unless row.payload_purged_at != nil or matches?(kind, row, payload),
      do: raise(ArgumentError, "delegation authority mismatch")

    :ok
  end

  def matches?(kind, row, payload) when is_map(payload) do
    row =
      Map.new(
        columns(kind),
        &{Atom.to_string(&1), Map.get(row, &1, Map.get(row, Atom.to_string(&1)))}
      )

    binding = payload[@key]

    if row["surface"] == "delegation" do
      valid_context?(binding) and row["conversation_id"] == nil and
        row["chat_id"] == "delegation:#{binding["delegation_id"]}" and
        row["user_id"] == binding["user_id"] and specific_match?(kind, row, binding)
    else
      is_nil(binding) and row["surface"] in ~w(telegram mobile) and human?(kind, row)
    end
  end

  def matches?(_, _, _), do: false

  defp valid_context?(%{"version" => 1} = binding) do
    Enum.all?(~w(delegation_id turn_id run_id), &match?({:ok, _}, Ecto.UUID.cast(binding[&1]))) and
      is_binary(binding["user_id"]) and binding["user_id"] != "" and
      is_integer(binding["grant_version"]) and
      binding["grant_version"] > 0 and
      Enum.all?(
        ~w(source_revision workflow_revision),
        &(is_integer(binding[&1]) and binding[&1] >= 0)
      ) and
      is_binary(binding["scope_hash"]) and Regex.match?(~r/^[a-f0-9]{64}$/, binding["scope_hash"])
  end

  defp valid_context?(_), do: false

  defp specific_match?(:run, row, binding),
    do: row["id"] == binding["run_id"] and row["trigger_type"] == "delegation_event"

  defp specific_match?(:action, row, binding),
    do:
      row["authorization_kind"] == "delegation_grant" and
        row["delegation_id"] == binding["delegation_id"] and
        row["delegation_turn_id"] == binding["turn_id"] and
        row["grant_version"] == binding["grant_version"] and row["run_id"] == binding["run_id"]

  defp human?(:run, _), do: true

  defp human?(:action, row),
    do:
      row["authorization_kind"] == "human_confirmed" and
        Enum.all?(~w(delegation_id delegation_turn_id grant_version), &is_nil(row[&1]))
end
