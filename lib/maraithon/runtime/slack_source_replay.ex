defmodule Maraithon.Runtime.SlackSourceReplay do
  @moduledoc false

  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.Repo
  alias Maraithon.Runtime.{SourceCycle, SourceCycleItem, SourceCycleProofs}

  @max_window_seconds 31 * 24 * 60 * 60

  @doc false
  def build(account, lower, upper, now \\ DateTime.utc_now())

  def build(%ConnectedAccount{} = account, lower, upper, now) do
    now_seconds = DateTime.to_unix(now, :second)

    with {:ok, replay} <- replay_for_bounds(account, lower, upper),
         true <- replay.upper <= now_seconds do
      {:ok, replay}
    else
      _invalid -> {:error, :invalid_slack_source_replay}
    end
  end

  def build(_account, _lower, _upper, _now), do: {:error, :invalid_slack_source_replay}

  @doc false
  def from_payload(account, payload, role, now \\ DateTime.utc_now())

  def from_payload(%ConnectedAccount{} = account, payload, role, _now)
      when is_map(payload) and role in ["discovery", "closure"] do
    case Map.get(payload, "source_replay_mode") do
      nil ->
        {:ok, nil}

      "historical" ->
        with {:ok, replay} <-
               replay_for_bounds(
                 account,
                 Map.get(payload, "source_replay_lower"),
                 Map.get(payload, "source_replay_upper")
               ),
             ^role <- Map.get(payload, "role"),
             reference when reference == replay.reference <-
               Map.get(payload, "source_replay_reference") do
          {:ok, Map.put(replay, :kind, Map.fetch!(replay, role_kind(role)))}
        else
          _invalid -> {:error, :invalid_slack_source_replay_payload}
        end

      _invalid ->
        {:error, :invalid_slack_source_replay_payload}
    end
  end

  def from_payload(_account, _payload, _role, _now),
    do: {:error, :invalid_slack_source_replay_payload}

  @doc false
  def validate_runtime_replay(%ConnectedAccount{}, nil, role)
      when role in ["discovery", "closure"],
      do: {:ok, nil}

  def validate_runtime_replay(%ConnectedAccount{} = account, replay, role)
      when is_map(replay) and role in ["discovery", "closure"] do
    with {:ok, expected} <-
           replay_for_bounds(account, Map.get(replay, :lower), Map.get(replay, :upper)),
         reference when reference == expected.reference <- Map.get(replay, :reference),
         kind when is_binary(kind) <- Map.get(replay, :kind),
         true <- kind == Map.fetch!(expected, role_kind(role)) do
      {:ok, Map.put(expected, :kind, kind)}
    else
      _invalid -> {:error, :invalid_slack_source_replay_payload}
    end
  end

  def validate_runtime_replay(_account, _replay, _role),
    do: {:error, :invalid_slack_source_replay_payload}

  @doc false
  def payload(replay) when is_map(replay) do
    %{
      "source_replay_mode" => "historical",
      "source_replay_lower" => Map.fetch!(replay, :lower),
      "source_replay_upper" => Map.fetch!(replay, :upper),
      "source_replay_reference" => Map.fetch!(replay, :reference)
    }
  end

  @doc false
  def watermark_kind?(kind, role)
      when is_binary(kind) and role in ["discovery", "closure"] do
    prefix = "slack_#{role}_replay:"

    if String.starts_with?(kind, prefix) do
      suffix = binary_part(kind, byte_size(prefix), byte_size(kind) - byte_size(prefix))
      byte_size(suffix) == 43 and String.match?(suffix, ~r/^[A-Za-z0-9_-]+$/)
    else
      false
    end
  end

  def watermark_kind?(_kind, _role), do: false

  @doc "Verifies both exact proof chains for a completed Slack replay."
  def verify(account_id, lower, upper) when is_integer(account_id) do
    with %ConnectedAccount{} = account <- Repo.get(ConnectedAccount, account_id),
         {:ok, replay} <- build(account, lower, upper),
         {:ok, discovery} <- verify_role(account, replay, "discovery"),
         {:ok, closure} <- verify_role(account, replay, "closure"),
         true <- discovery.items == closure.items do
      {:ok,
       %{
         source_replay_reference: replay.reference,
         provider_window: %{lower: replay.lower, upper: replay.upper},
         source_items: length(discovery.items),
         discovery_cycle_id: discovery.cycle.id,
         discovery_counts: discovery.counts,
         closure_cycle_id: closure.cycle.id,
         closure_counts: closure.counts
       }}
    else
      nil -> {:error, :source_account_not_found}
      false -> {:error, :slack_source_replay_role_manifests_differ}
      {:error, _reason} = error -> error
      _invalid -> {:error, :slack_source_replay_verification_failed}
    end
  end

  def verify(_account_id, _lower, _upper), do: {:error, :invalid_slack_source_replay}

  @doc false
  def verify_role(%ConnectedAccount{} = account, replay, role)
      when is_map(replay) and role in ["discovery", "closure"] do
    kind = Map.fetch!(replay, role_kind(role))

    with {:ok, cycle} <- replay_cycle(account.id, kind, role),
         2 <- cycle.proof_version,
         :ok <- verify_cycle_bounds(cycle, replay),
         {:ok, counts} <- SourceCycleProofs.verify_complete(cycle),
         {:ok, items} <- verified_items(cycle, replay),
         :ok <- verify_cursor(account.id, kind, replay.upper) do
      {:ok,
       %{
         acquisition_job_id: cycle.acquisition_job_id,
         cycle: cycle,
         counts: counts,
         items: items
       }}
    else
      version when is_integer(version) -> {:error, :slack_source_replay_proof_version_mismatch}
      {:error, _reason} = error -> error
      _invalid -> {:error, :slack_source_replay_verification_failed}
    end
  end

  def verify_role(_account, _replay, _role), do: {:error, :invalid_slack_source_replay}

  defp slack_account?(%ConnectedAccount{provider: "slack:" <> suffix}) do
    suffix != "" and not String.contains?(suffix, ":user:")
  end

  defp slack_account?(_account), do: false

  defp replay_for_bounds(%ConnectedAccount{} = account, lower, upper) do
    with true <- slack_account?(account),
         true <- account.status == "connected",
         lower when is_integer(lower) and lower >= 0 <- cursor_integer(lower),
         upper when is_integer(upper) and upper > lower <- cursor_integer(upper),
         true <- upper - lower <= @max_window_seconds do
      reference = replay_reference(account.id, lower, upper)

      {:ok,
       %{
         lower: lower,
         upper: upper,
         reference: reference,
         discovery_kind: watermark_kind("discovery", reference),
         closure_kind: watermark_kind("closure", reference)
       }}
    else
      _invalid -> {:error, :invalid_slack_source_replay}
    end
  end

  defp replay_cycle(account_id, kind, role) do
    cycles =
      SourceCycle
      |> where(
        [cycle],
        cycle.connected_account_id == ^account_id and cycle.cursor_kind == ^kind and
          cycle.role == ^role
      )
      |> order_by([cycle], asc: cycle.captured_at, asc: cycle.id)
      |> Repo.all()

    case cycles do
      [cycle] -> {:ok, cycle}
      [] -> {:error, {:slack_source_replay_cycle_missing, role}}
      _many -> {:error, {:slack_source_replay_cycle_not_unique, role}}
    end
  end

  defp verify_cycle_bounds(cycle, replay) do
    if cycle.lower_cursor == Integer.to_string(replay.lower) and
         cycle.upper_cursor == Integer.to_string(replay.upper) and
         cycle.boundary == "lower_inclusive_upper_exclusive" do
      :ok
    else
      {:error, :slack_source_replay_cycle_bounds_mismatch}
    end
  end

  defp verified_items(cycle, replay) do
    items =
      SourceCycleItem
      |> where([item], item.cycle_id == ^cycle.id)
      |> order_by([item], asc: item.ordinal)
      |> select(
        [item],
        {item.source_ref_digest, item.source_identity_digest, item.provider_occurred_at}
      )
      |> Repo.all()

    complete? =
      length(items) == cycle.source_item_count and
        Enum.all?(items, fn {_ref, _identity, occurred_at} ->
          is_struct(occurred_at, DateTime) and
            DateTime.to_unix(occurred_at, :second) >= replay.lower and
            DateTime.to_unix(occurred_at, :second) < replay.upper
        end)

    if complete?, do: {:ok, items}, else: {:error, :slack_source_replay_item_bounds_mismatch}
  end

  defp verify_cursor(account_id, kind, upper) do
    upper_value = Integer.to_string(upper)

    case SourceCursors.get(account_id, kind) do
      %{value: ^upper_value} -> :ok
      _other -> {:error, :slack_source_replay_cursor_incomplete}
    end
  end

  defp cursor_integer(value) when is_integer(value), do: value

  defp cursor_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _invalid -> nil
    end
  end

  defp cursor_integer(_value), do: nil

  defp replay_reference(account_id, lower, upper) do
    ["slack-source-replay-v1", account_id, lower, upper]
    |> Enum.join(":")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp watermark_kind(role, reference), do: "slack_#{role}_replay:#{reference}"
  defp role_kind("discovery"), do: :discovery_kind
  defp role_kind("closure"), do: :closure_kind
end
