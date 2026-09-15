defmodule Maraithon.Delegations.Evaluation do
  @moduledoc "The controlled Kent-to-Kent evaluation. Preflight is read-only and never calls a model."
  alias Maraithon.{Accounts, AssistantIdentities, ConnectedAccounts, LLM}
  alias Maraithon.Connectors.GoogleCalendar
  alias Maraithon.Delegations.{Preferences, Scheduling}

  @doc "Check the actual recipient's offered dates and wording before the fixture accepts a time."
  def verify_offer(scenario, slots, body, requested_at) do
    valid =
      is_list(slots) and length(slots) == 3 and is_binary(body) and
        not Regex.match?(
          ~r/\b(?:I am|I'm|I’m|as)\s+(?:\w+[’']?s?\s+){0,3}(?:AI\s+)?assistant\b/iu,
          body
        ) and
        Enum.all?(slots, fn slot ->
          {:ok, first, _} = DateTime.from_iso8601(slot["start_at"])
          {:ok, last, _} = DateTime.from_iso8601(slot["end_at"])
          prefs = %{"timezone" => slot["timezone"]}
          date = Preferences.local_time(first, prefs) |> DateTime.to_date()
          requested = Preferences.local_time(requested_at, prefs) |> DateTime.to_date()
          monday = Date.add(requested, 8 - Date.day_of_week(requested))

          next_week? =
            Date.compare(date, monday) != :lt and Date.compare(date, Date.add(monday, 7)) == :lt

          String.contains?(body, Scheduling.slot_label(slot)) and
            DateTime.diff(last, first) == 1_800 and
            (scenario["expect"]["requested_week_offset"] != 1 or next_week?)
        end)

    if valid, do: :ok, else: {:error, :received_offer_not_proven}
  end

  def scenarios do
    :maraithon
    |> Application.app_dir("priv/evals/delegations/kent_pair.json")
    |> File.read!()
    |> Jason.decode!()
  end

  def preflight do
    spec = scenarios()
    user_id = spec["owner"]["email"]
    expected = [user_id, spec["counterparty"]["email"]]
    accounts = ConnectedAccounts.list_for_user(user_id)
    reports = Enum.map(expected, &account_report(user_id, &1, accounts))
    model = Accounts.assistant_model(user_id) || LLM.openrouter_model()

    %{
      "phase" => "preflight",
      "model" => model,
      "expected_model" => spec["model"],
      "accounts" => reports,
      "model_calls" => 0,
      "messages_sent" => 0,
      "events_created" => 0,
      "accounts_ready" => Enum.all?(reports, &(&1["status"] == "ready")),
      "model_ready" => model == spec["model"],
      "execution_ready" => Maraithon.Delegations.Commands.execution_ready?(),
      "live_eval_passed" => false
    }
  end

  defp account_report(user_id, email, accounts) do
    matching =
      Enum.filter(accounts, fn a ->
        a.status == "connected" and
          (a.provider == "google:#{email}" or a.metadata["email"] == email or
             a.metadata["account_email"] == email or a.external_account_id == email)
      end)

    with [account] <- matching,
         {:ok, identity} <- AssistantIdentities.gmail_snapshot(user_id, "as_user", account.id),
         true <- identity["email"] == email,
         true <-
           Enum.any?(
             account.scopes,
             &(&1 in [
                 "https://mail.google.com/",
                 "https://www.googleapis.com/auth/gmail.compose",
                 "https://www.googleapis.com/auth/gmail.send",
                 "https://www.googleapis.com/auth/gmail.modify"
               ])
           ),
         {:ok, _events} <-
           GoogleCalendar.events_in_window(
             user_id,
             account.id,
             DateTime.utc_now(),
             DateTime.add(DateTime.utc_now(), 1, :day)
           ) do
      %{"email" => email, "account_id" => account.id, "status" => "ready"}
    else
      [] ->
        %{"email" => email, "status" => "not_connected"}

      [_ | _] ->
        %{"email" => email, "status" => "ambiguous_account"}

      false ->
        %{"email" => email, "status" => "sender_or_scope_mismatch"}

      {:error, reason} ->
        %{
          "email" => email,
          "status" => "access_failed",
          "failure" => Maraithon.Redaction.error_class(reason)
        }
    end
  end
end
