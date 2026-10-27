defmodule Maraithon.Delegations.Ingress do
  @moduledoc "Route provider messages under the same transaction as source persistence."
  import Ecto.Query
  alias Maraithon.{Delegations, Repo}
  alias Maraithon.Connectors.Gmail
  alias Maraithon.Delegations.{Delegation, Event, GmailThreads, Outbox, ReplyIntent, Scope}
  alias Maraithon.TelegramAssistant.PreparedAction

  def active?(user_id), do: Repo.exists?(from d in Delegation, where: d.user_id == ^user_id)

  def gmail!(user_id, account_id, message) when is_integer(account_id) do
    unless Repo.in_transaction?(), do: raise(ArgumentError, "source routing needs a transaction")
    thread_id = field(message, :thread_id)
    message_id = field(message, :message_id)

    if is_binary(thread_id) and is_binary(message_id) do
      bound =
        Repo.all(
          from d in Delegation,
            where:
              d.user_id == ^user_id and d.connected_account_id == ^account_id and
                d.provider == "gmail" and d.provider_thread_id == ^thread_id,
            order_by: [desc: d.inserted_at],
            limit: 10,
            lock: "FOR UPDATE"
        )
        |> Enum.map(&Delegation.hydrate/1)

      candidates =
        if bound == [], do: GmailThreads.candidates(user_id, account_id, message), else: bound

      live = Enum.filter(candidates, &Delegation.live?/1)
      candidates = if bound != [] or live == [], do: candidates, else: live

      Enum.each(candidates, fn d ->
        override = if length(live) > 1, do: "source_gap"
        accept!(d, message, account_id, override)
      end)
    end

    :ok
  end

  def gmail!(_, _, _), do: :ok

  @doc "Record the original mailbox evidence before an assistant opens its own thread."
  def gmail_source!(d, scope, message) do
    unless Repo.in_transaction?(), do: raise(ArgumentError, "source routing needs a transaction")

    if is_nil(d.provider_thread_id) and field(message, :thread_id) == scope["source_thread_id"] and
         is_integer(scope["source_account_id"]) do
      d = Repo.get!(Delegation, d.id) |> Delegation.hydrate()

      source_scope =
        if is_binary(scope["source_user_email"]),
          do: Map.update!(scope, "identity", &Map.put(&1, "email", scope["source_user_email"])),
          else: scope

      accept!(d, message, scope["source_account_id"], nil, source_scope)
    end
  end

  defp accept!(d, message, account_id, override, source_scope \\ nil) do
    id = field(message, :message_id)
    key = "gmail:#{account_id}:#{id}"

    unless Repo.exists?(from e in Event, where: e.delegation_id == ^d.id and e.event_key == ^key) do
      grant = Delegations.current_grant(d)
      occurred_at = field(message, :internal_date) || Maraithon.Runtime.DatabaseClock.now!()

      classification =
        override ||
          if DateTime.compare(occurred_at, d.inserted_at) == :lt,
            do: "historical",
            else: classify(message, source_scope || grant.data["scope"], own_action?(d, message))

      {d, classification} = follow_thread(d, message, account_id, classification)

      GmailThreads.remember!(
        d,
        account_id,
        message,
        classification in ~w(historical reply acknowledgement own_send human_send stop)
      )

      # Arrival invalidates unsent decisions before a cursor can advance. The
      # coordinator may be asleep or on another node; its mailbox isn't authority.
      d =
        if Delegation.live?(d) and
             classification in ~w(reply human_send stop bounce scope_change source_gap thread_changed) do
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
          "original_internet_message_id" =>
            bounded(field(message, :original_internet_message_id)),
          "thread_id" => field(message, :thread_id),
          "in_reply_to" => bounded(field(message, :in_reply_to)),
          "references" => bounded(field(message, :references))
        },
        %{source_ref: id, occurred_at: occurred_at}
      )
    end
  end

  defp follow_thread(d, message, account, classification) do
    thread = field(message, :thread_id)

    changed? =
      account == d.connected_account_id and not is_nil(d.provider_thread_id) and
        thread != d.provider_thread_id

    if changed? and Delegation.live?(d) and classification in ~w(reply human_send stop) do
      case GmailThreads.rollover(d, message) do
        {:ok, threads} ->
          data = Map.put(d.data, "gmail_threads", threads)

          {d |> Delegation.changeset(%{provider_thread_id: thread, data: data}) |> Repo.update!(),
           classification}

        {:error, _} ->
          {d, "thread_changed"}
      end
    else
      {d, classification}
    end
  end

  @doc "Classify by bound account and exact participants, never by a display name."
  def classify(message, scope, own_action? \\ false)

  def classify(message, %{"provider" => "slack"} = scope, own_action?),
    do: Maraithon.Delegations.SlackSource.classify(message, scope, own_action?)

  def classify(message, scope, own_action?) do
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

      ReplyIntent.thanks_only?(message) and
          GmailThreads.same_subject?(field(message, :subject), scope["subject"]) ->
        "acknowledgement"

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
