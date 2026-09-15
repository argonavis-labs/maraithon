defmodule Maraithon.Delegations.Ingress do
  @moduledoc "Route fetched Gmail messages under the same transaction as source persistence."
  import Ecto.Query
  alias Maraithon.{Delegations, Repo}
  alias Maraithon.Connectors.Gmail
  alias Maraithon.Delegations.{Delegation, Event, Outbox, Scope}
  alias Maraithon.TelegramAssistant.PreparedAction

  def active?(user_id), do: Repo.exists?(from d in Delegation, where: d.user_id == ^user_id)

  def gmail!(user_id, account_id, message) when is_integer(account_id) do
    unless Repo.in_transaction?(), do: raise(ArgumentError, "source routing needs a transaction")
    thread_id = field(message, :thread_id)
    message_id = field(message, :message_id)

    if is_binary(thread_id) and is_binary(message_id) do
      Repo.all(
        from d in Delegation,
          where:
            d.user_id == ^user_id and d.connected_account_id == ^account_id and
              d.provider == "gmail" and d.provider_thread_id == ^thread_id,
          order_by: [desc: d.inserted_at],
          limit: 10,
          lock: "FOR UPDATE"
      )
      |> Enum.each(&accept!(Delegation.hydrate(&1), message))
    end

    :ok
  end

  def gmail!(_, _, _), do: :ok

  defp accept!(d, message) do
    id = field(message, :message_id)
    key = "gmail:#{d.connected_account_id}:#{id}"

    unless Repo.exists?(from e in Event, where: e.delegation_id == ^d.id and e.event_key == ^key) do
      grant = Delegations.current_grant(d)
      occurred_at = field(message, :internal_date) || Maraithon.Runtime.DatabaseClock.now!()

      classification =
        if DateTime.compare(occurred_at, d.inserted_at) == :lt,
          do: "historical",
          else: classify(message, grant.data["scope"], own_action?(d, message))

      # Arrival invalidates unsent decisions before a cursor can advance. The
      # coordinator may be asleep or on another node; its mailbox isn't authority.
      d =
        if classification in ~w(reply human_send stop bounce scope_change source_gap) do
          d |> Delegation.changeset(%{source_revision: d.source_revision + 1}) |> Repo.update!()
        else
          d
        end

      Outbox.append!(
        d,
        "inbound_message",
        key,
        %{
          "classification" => classification,
          "source_revision" => d.source_revision,
          "message_id" => id,
          "internet_message_id" => bounded(field(message, :internet_message_id)),
          "in_reply_to" => bounded(field(message, :in_reply_to)),
          "references" => bounded(field(message, :references))
        },
        %{source_ref: id, occurred_at: occurred_at}
      )
    end
  end

  @doc "Classify by bound account and exact participants, never by a display name."
  def classify(message, scope, own_action? \\ false) do
    participants = Gmail.message_participants(message)
    senders = for p <- participants, p["role"] == "from", do: p["identifier"]["email"]
    own = String.downcase(scope["identity"]["email"])
    allowed = MapSet.new([own | Scope.email_participants(scope)], &String.downcase/1)
    user = if scope["actor"] == "as_assistant", do: scope["source_user_email"]
    auto = field(message, :auto_submitted)
    text = (field(message, :text_body) || "") |> String.trim() |> String.downcase()

    cond do
      "DRAFT" in (field(message, :labels) || []) ->
        "draft"

      own_action? ->
        "own_send"

      length(senders) != 1 ->
        "source_gap"

      senders == [own] or (is_binary(user) and senders == [String.downcase(user)]) ->
        "human_send"

      field(message, :return_path) == "<>" and
          String.starts_with?(field(message, :content_type) || "", "multipart/report") ->
        "bounce"

      is_binary(auto) and String.downcase(auto) != "no" ->
        "auto_reply"

      Enum.any?(participants, &(not MapSet.member?(allowed, &1["identifier"]["email"]))) ->
        "scope_change"

      text in ["stop", "please stop", "unsubscribe", "please stop emailing me"] ->
        "stop"

      true ->
        "reply"
    end
  end

  defp own_action?(d, message) do
    sent? = "SENT" in (field(message, :labels) || [])
    message_id = field(message, :message_id)

    sent? and
      (Repo.exists?(
         from e in Event,
           where:
             e.delegation_id == ^d.id and e.user_id == ^d.user_id and
               e.kind == "send_receipt" and e.source_ref == ^message_id
       ) or original_action?(d, message))
  end

  defp original_action?(d, message) do
    ids = [field(message, :internet_message_id), field(message, :original_internet_message_id)]

    Enum.any?(ids, &matches_action?(d, &1))
  end

  defp matches_action?(d, message_id) do
    with [_, id] <-
           Regex.run(
             ~r/^<maraithon\.([a-f0-9-]+)@maraithon\.com>$/,
             message_id || ""
           ),
         {:ok, id} <- Ecto.UUID.cast(id),
         %PreparedAction{} = action <-
           Repo.get_by(PreparedAction,
             id: id,
             user_id: d.user_id,
             delegation_id: d.id,
             authorization_kind: "delegation_grant"
           ),
         action = PreparedAction.hydrate_payload(action) do
      # A forged inbound Message-ID cannot claim to be our outbound message.
      message_id == Maraithon.TelegramAssistant.ActionReconciliation.message_id(action)
    else
      _ -> false
    end
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp bounded(nil), do: nil
  defp bounded(value), do: Maraithon.PromptBudget.truncate_utf8(value, 2_000)
end
