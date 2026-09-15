defmodule Maraithon.Delegations.Scope do
  @moduledoc "Derives a reviewable grant from a todo, a verified identity, and source evidence."
  alias Maraithon.{Repo, OAuth, Crm, AssistantIdentities, UserIdentity}
  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Connectors.Gmail
  alias Maraithon.Delegations.Preferences
  alias Maraithon.Todos.{Todo, Workflow}

  def preview(%Todo{} = todo, attrs) do
    actor = Map.get(attrs, "actor", "as_user")
    kind = Map.get(attrs, "kind", "information")

    with true <-
           actor in ~w(as_user as_assistant) and kind in ~w(information scheduling coordination),
         true <- todo.status in ~w(open snoozed),
         %ConnectedAccount{status: "connected"} = account <- account(todo),
         {:ok, source, identity} <- source(todo, account, actor),
         {:ok, scope} <- build(todo, source, identity, attrs, Preferences.get(todo.user_id)) do
      # Editable form values are explicit user input at submission. This hash
      # protects the derived source and identity the user actually reviewed.
      {:ok, Map.put(scope, "scope_hash", hash(Map.drop(scope, ~w(outcome instruction to cc))))}
    else
      {:error, _} = error -> error
      _ -> {:error, :delegation_source_unavailable}
    end
  end

  def hash(value) do
    value
    |> Maraithon.AssistantHarness.PromptStability.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def todo_fingerprint(todo),
    do:
      hash(
        Map.take(todo, [
          :id,
          :source,
          :source_account_id,
          :source_item_id,
          :title,
          :summary,
          :next_action,
          :workflow,
          :status,
          :counterparty_person_id
        ])
      )

  defp account(%{source_account_id: id, user_id: user_id}) when is_integer(id),
    do: Repo.get_by(ConnectedAccount, id: id, user_id: user_id)

  defp account(_), do: nil

  defp source(%{source: "gmail"} = todo, account, actor) do
    with {:ok, identity} <- AssistantIdentities.gmail_snapshot(todo.user_id, actor, account.id),
         {:ok, token} <-
           OAuth.get_valid_access_token(todo.user_id, account.provider, exact?: true),
         {:ok, message} <- Gmail.fetch_message(token, todo.source_item_id, access_token: true),
         false <- "DRAFT" in message.labels do
      own = [identity["email"] | UserIdentity.identity(todo.user_id).emails]
      participants = Gmail.message_participants(message)
      others = Enum.reject(participants, &(get_in(&1, ["identifier", "email"]) in own))
      from = addresses(others, "from")
      to = if from == [], do: addresses(others, "to"), else: from
      thread = if identity["account_id"] == account.id, do: message.thread_id

      {:ok,
       %{
         "provider" => "gmail",
         "source_account_id" => account.id,
         "source_message_id" => message.message_id,
         "source_thread_id" => message.thread_id,
         "thread_id" => thread,
         "subject" => message.subject,
         "internet_message_id" => message.internet_message_id,
         "to" => to,
         "cc" => [],
         "evidence" => [
           %{"source" => "gmail", "account_id" => account.id, "id" => message.message_id}
         ]
       }, identity}
    else
      {:error, _} = error -> error
      _ -> {:error, :source_is_not_sent_mail}
    end
  end

  defp source(%{source: "slack"} = todo, account, actor),
    do: Maraithon.Delegations.SlackIdentity.preview(todo, account, actor)

  defp source(_, _, _), do: {:error, :unsupported_delegation_source}

  defp build(todo, source, identity, attrs, prefs) do
    workflow = Workflow.current(todo)
    owner_id = if workflow["owner"]["kind"] == "person", do: workflow["owner"]["id"]
    person = Crm.get_person_for_user(todo.user_id, todo.counterparty_person_id || owner_id)
    to = Map.get(attrs, "to", source["to"])
    cc = Map.get(attrs, "cc", source["cc"])
    outcome = Map.get(attrs, "outcome", workflow["outcome"])
    instruction = Map.get(attrs, "instruction", "")
    gmail? = source["provider"] == "gmail"

    valid_destination =
      if gmail?,
        do: valid_emails?(to, false) and valid_emails?(cc, true),
        else: to == source["to"] and cc == []

    if valid_destination and text?(outcome, 2_000, false) and text?(instruction, 2_000, true) do
      {:ok,
       Map.merge(source, %{
         "actor" => identity["actor"],
         "kind" => Map.get(attrs, "kind", "information"),
         "identity" => identity,
         "outcome" => outcome,
         "instruction" => instruction,
         "to" => Enum.uniq(to),
         "cc" => Enum.uniq(cc),
         "policy_version" => 1,
         "todo_fingerprint" => todo_fingerprint(todo),
         "workflow_revision" => workflow["revision"],
         "task_owner" => workflow["owner"],
         "counterparty_id" => person && person.id,
         "counterparty_label" =>
           (person && person.display_name) || todo.counterparty_label || Enum.join(to, ", "),
         "facts" => String.slice(todo.summary || "", 0, 8_000),
         "limits" =>
           Map.take(
             prefs,
             ~w(sends_per_7d reminders_per_cycle model_calls_per_turn micro_usd_per_30d user_micro_usd_per_day)
           ),
         "allowed" =>
           ~w(reply ask answer_from_evidence follow_up propose_computed_times book_agreed_time),
         "reserved" =>
           ~w(new_recipients money contracts credentials unrelated_information attachments)
       })}
    else
      {:error, :invalid_delegation_scope}
    end
  end

  def valid_emails?(values, allow_empty) do
    is_list(values) and (allow_empty or values != []) and length(values) <= 20 and
      Enum.all?(
        values,
        &(is_binary(&1) and byte_size(&1) <= 320 and
            Regex.match?(~r/^[^\s<>@,;]+@[^\s<>@,;]+\.[^\s<>@,;]+$/, &1))
      )
  end

  defp addresses(people, role),
    do: for(p <- people, p["role"] == role, do: p["identifier"]["email"])

  defp text?(s, max, empty),
    do: is_binary(s) and byte_size(s) <= max and (empty or String.trim(s) != "")
end
