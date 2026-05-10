defmodule Maraithon.ActionLedger do
  @moduledoc """
  Records and explains material assistant decisions and side effects.

  Ledger entries are intentionally stored and returned through the same
  redaction pass. The ledger is for durable decision accountability, not raw
  prompt, token, webhook, or tool-output storage.
  """

  import Ecto.Query

  alias Maraithon.ActionLedger.Action
  alias Maraithon.Normalization
  alias Maraithon.Redaction
  alias Maraithon.Repo

  @default_limit 20
  @max_limit 100
  @default_retention_days 180

  def record(attrs) when is_map(attrs) do
    attrs
    |> normalize_attrs()
    |> redact_attrs()
    |> then(fn normalized ->
      %Action{}
      |> Action.changeset(normalized)
      |> Repo.insert()
    end)
  end

  def record(_attrs), do: {:error, :invalid_action_ledger_attrs}

  def list_recent(user_id, opts \\ [])

  def list_recent(user_id, opts) when is_binary(user_id) and is_list(opts) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> normalize_limit()
    event_type = Keyword.get(opts, :event_type)

    Action
    |> where([action], action.user_id == ^user_id)
    |> maybe_filter_event_type(event_type)
    |> order_by([action], desc: action.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_recent(_user_id, _opts), do: []

  def find_by_object(user_id, object_type, object_id)
      when is_binary(user_id) and is_binary(object_type) and is_binary(object_id) do
    Action
    |> where([action], action.user_id == ^user_id)
    |> where(
      [action],
      fragment("? ->> ? = ?", action.result_object_refs, ^object_type, ^object_id) or
        fragment("? ->> ? = ?", action.metadata, ^object_type, ^object_id)
    )
    |> order_by([action], desc: action.inserted_at)
    |> Repo.all()
  end

  def find_by_object(_user_id, _object_type, _object_id), do: []

  def explain(user_id, action_id) when is_binary(user_id) and is_binary(action_id) do
    case Repo.get_by(Action, id: action_id, user_id: user_id) do
      %Action{} = action -> {:ok, explain_action(action)}
      nil -> {:error, :not_found}
    end
  end

  def explain(_user_id, _action_id), do: {:error, :invalid_action_reference}

  def explain_action(%Action{} = action) do
    %{
      id: action.id,
      user_id: action.user_id,
      agent_id: action.agent_id,
      surface: action.surface,
      event_type: action.event_type,
      status: action.status,
      reason_code: get_in(action.policy_decision || %{}, ["reason_code"]),
      message: get_in(action.policy_decision || %{}, ["message"]),
      confirmation_state: action.confirmation_state,
      source_evidence: redacted_map(action.source_evidence),
      model_summary: redacted_string(action.model_summary),
      result_object_refs: redacted_map(action.result_object_refs),
      remediation_hint: action.remediation_hint,
      metadata: redacted_map(action.metadata),
      inserted_at: action.inserted_at
    }
  end

  @doc """
  Return the default redacted map representation used by diagnostics exports.
  """
  def redacted_action(%Action{} = action) do
    %{
      id: action.id,
      user_id: action.user_id,
      agent_id: action.agent_id,
      surface: action.surface,
      event_type: action.event_type,
      status: action.status,
      source_evidence: redacted_map(action.source_evidence),
      policy_decision: redacted_map(action.policy_decision),
      model_summary: redacted_string(action.model_summary),
      confirmation_state: action.confirmation_state,
      result_object_refs: redacted_map(action.result_object_refs),
      remediation_hint: action.remediation_hint,
      metadata: redacted_map(action.metadata),
      inserted_at: action.inserted_at,
      updated_at: action.updated_at
    }
  end

  def retention_days do
    :maraithon
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:retention_days, @default_retention_days)
    |> normalize_retention_days()
  end

  def redaction_manifest do
    %{
      retention_days: retention_days(),
      default_view: "redacted",
      disallowed_content: [
        "raw secrets",
        "access tokens",
        "refresh tokens",
        "authorization headers",
        "cookies",
        "raw prompts",
        "raw webhook bodies",
        "raw tool outputs"
      ],
      redaction: "Maraithon.Redaction field-name and credential-pattern scanners"
    }
  end

  def purge_expired(opts \\ []) when is_list(opts) do
    days = opts |> Keyword.get(:retention_days, retention_days()) |> normalize_retention_days()
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 24 * 60 * 60, :second)

    {count, _rows} =
      Action
      |> where([action], action.inserted_at < ^cutoff)
      |> Repo.delete_all()

    {:ok, count}
  end

  defp maybe_filter_event_type(query, nil), do: query
  defp maybe_filter_event_type(query, ""), do: query

  defp maybe_filter_event_type(query, event_type) when is_binary(event_type) do
    where(query, [action], action.event_type == ^event_type)
  end

  defp normalize_attrs(attrs) do
    %{
      user_id: read_string(attrs, :user_id),
      agent_id: read_string(attrs, :agent_id),
      surface: read_string(attrs, :surface, "system"),
      event_type: read_string(attrs, :event_type, "tool.executed"),
      status: read_string(attrs, :status, "completed"),
      source_evidence: read_map(attrs, :source_evidence),
      policy_decision: read_map(attrs, :policy_decision),
      model_summary: read_string(attrs, :model_summary),
      confirmation_state: read_string(attrs, :confirmation_state),
      result_object_refs: read_map(attrs, :result_object_refs),
      remediation_hint: read_string(attrs, :remediation_hint),
      metadata: read_map(attrs, :metadata)
    }
  end

  defp redact_attrs(attrs) do
    %{
      attrs
      | source_evidence: redacted_map(attrs.source_evidence),
        policy_decision: redacted_map(attrs.policy_decision),
        model_summary: redacted_string(attrs.model_summary),
        result_object_refs: redacted_map(attrs.result_object_refs),
        metadata: redacted_map(attrs.metadata)
    }
  end

  defp redacted_map(value) when is_map(value), do: value |> Redaction.redact() |> stringify_keys()
  defp redacted_map(_value), do: %{}

  defp redacted_string(nil), do: nil
  defp redacted_string(value) when is_binary(value), do: Redaction.redact_string(value)
  defp redacted_string(value), do: value |> to_string() |> Redaction.redact_string()

  defp read_string(attrs, key, default \\ nil),
    do: Normalization.read_string(attrs, key, default)

  defp read_map(attrs, key), do: Normalization.read_map(attrs, key)

  defp stringify_keys(value), do: Normalization.stringify_keys(value)

  defp normalize_limit(limit), do: Normalization.clamp_limit(limit, @default_limit, @max_limit)

  defp normalize_retention_days(days) when is_integer(days) and days > 0, do: days

  defp normalize_retention_days(days) when is_binary(days) do
    days
    |> Normalization.parse_integer()
    |> normalize_retention_days()
  end

  defp normalize_retention_days(_days), do: @default_retention_days
end
