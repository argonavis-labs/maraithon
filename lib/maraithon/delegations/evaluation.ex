defmodule Maraithon.Delegations.Evaluation do
  @moduledoc "The controlled Kent-to-Kent evaluation. Preflight is read-only and never calls a model."
  alias Maraithon.{Accounts, AssistantIdentities, ConnectedAccounts, LLM}
  alias Maraithon.Connectors.GoogleCalendar
  alias Maraithon.Delegations.{Preferences, Scheduling}
  alias Maraithon.HTTP.Admission
  alias Maraithon.Runtime.PeriodicJobs

  @doc "Leave one working hour for the live fixture, including its normal undo windows."
  def window(now, prefs) do
    {:ok, first} = Time.from_iso8601(prefs["work_start"] <> ":00")
    {:ok, last} = Time.from_iso8601(prefs["work_end"] <> ":00")

    if Time.diff(last, first) < 3600 do
      {:error, :eval_work_window_too_short}
    else
      start = Preferences.next_work_time(now, prefs)
      deadline = DateTime.add(start, 1, :hour)

      if Time.diff(last, DateTime.to_time(Preferences.local_time(start, prefs))) >= 3600 do
        {:ok, start, deadline}
      else
        next =
          Preferences.local_time(start, prefs)
          |> DateTime.to_date()
          |> Date.add(1)
          |> Preferences.from_local(~T[00:00:00], prefs)
          |> Preferences.next_work_time(prefs)

        {:ok, next, DateTime.add(next, 1, :hour)}
      end
    end
  end

  @doc "Check the actual recipient's offered dates and wording before the fixture accepts a time."
  def verify_offer(scenario, slots, body, requested_at, actor \\ "as_user") do
    expected = scenario["expect"]

    valid =
      is_list(slots) and length(slots) == 3 and is_binary(body) and
        (actor == "as_assistant" or
           not Regex.match?(
             ~r/\b(?:I am|I'm|I’m|as)\s+(?:\w+[’']?s?\s+){0,3}(?:AI\s+)?assistant\b/iu,
             body
           )) and
        Enum.all?(slots, fn slot ->
          {:ok, first, _} = DateTime.from_iso8601(slot["start_at"])
          {:ok, last, _} = DateTime.from_iso8601(slot["end_at"])
          prefs = %{"timezone" => slot["timezone"]}
          local_start = Preferences.local_time(first, prefs)
          date = DateTime.to_date(local_start)
          requested = Preferences.local_time(requested_at, prefs) |> DateTime.to_date()
          monday = Date.add(requested, 8 - Date.day_of_week(requested))

          next_week? =
            Date.compare(date, monday) != :lt and Date.compare(date, Date.add(monday, 7)) == :lt

          String.contains?(body, Scheduling.slot_label(slot)) and
            DateTime.diff(last, first) == (expected["duration_min"] || 30) * 60 and
            (expected["requested_week_offset"] != 1 or next_week?) and
            (expected["afternoon_only"] != true or local_start.hour >= 12)
        end)

    if valid, do: :ok, else: {:error, :received_offer_not_proven}
  end

  def scenarios do
    :maraithon
    |> Application.app_dir("priv/evals/delegations/kent_pair.json")
    |> File.read!()
    |> Jason.decode!()
  end

  def preflight(actor \\ "as_user") do
    spec = scenarios()
    user_id = spec["owner"]["email"]
    expected = [user_id, spec["counterparty"]["email"]]
    accounts = ConnectedAccounts.list_for_user(user_id)
    reports = Enum.map(expected, &account_report(user_id, &1, accounts))
    model = Accounts.assistant_model(user_id) || LLM.openrouter_model()
    assistant = if actor == "as_assistant", do: assistant_report(user_id, accounts, spec)

    %{
      "phase" => "preflight",
      "actor" => actor,
      "assistant" => assistant,
      "model" => model,
      "expected_model" => spec["model"],
      "accounts" => reports,
      "model_calls" => 0,
      "messages_sent" => 0,
      "events_created" => 0,
      "accounts_ready" =>
        Enum.all?(reports, &(&1["status"] == "ready")) and
          (actor == "as_user" or (actor == "as_assistant" and assistant["status"] == "ready")),
      "model_ready" => model == spec["model"],
      "budget_ready" => Maraithon.Delegations.Budget.account_budget_ok?(DateTime.utc_now()),
      "development_spending" => Maraithon.LLM.CostMonitor.development_spending?(),
      "execution_ready" => Maraithon.Delegations.Commands.execution_ready?(),
      "live_eval_passed" => false
    }
  end

  defp assistant_report(user_id, accounts, spec) do
    with {:ok, identity} <-
           read_probe(fn -> AssistantIdentities.gmail_snapshot(user_id, "as_assistant", nil) end),
         true <- identity["email"] == spec["assistant"]["email"],
         account when not is_nil(account) <-
           Enum.find(accounts, &(&1.id == identity["account_id"])),
         true <- AssistantIdentities.assistant_account?(account),
         false <-
           Enum.any?(ConnectedAccounts.list_personal_for_user(user_id), &(&1.id == account.id)) do
      %{
        "status" => "ready",
        "email" => identity["email"],
        "account_id" => account.id,
        "display_name" => identity["display_name"],
        "disclose_ai" => identity["disclose_ai"],
        "isolated_from_personal_sources" => true
      }
    else
      {:error, :gmail_sending_permission_required} ->
        %{"status" => "gmail_sending_permission_required"}

      {:error, reason} ->
        access_failure(reason)

      _ ->
        %{"status" => "assistant_setup_required"}
    end
  end

  defp account_report(user_id, email, accounts) do
    matching =
      Enum.filter(accounts, fn a ->
        a.status == "connected" and
          (a.provider == "google:#{email}" or a.metadata["email"] == email or
             a.metadata["account_email"] == email or a.external_account_id == email)
      end)

    with [account] <- matching,
         {:ok, identity} <-
           read_probe(fn -> AssistantIdentities.gmail_snapshot(user_id, "as_user", account.id) end),
         true <- identity["email"] == email,
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
        Map.put(access_failure(reason), "email", email)
    end
  end

  # A competing mailbox reader can reject this read locally for one second.
  # Bound retries to two short waits in this operator probe, never a coordinator.
  # Provider failures and longer cooldowns are reported without retrying.
  defp read_probe(read, retries \\ 2) do
    result = read.()

    case result do
      {:error, reason} when retries > 0 ->
        case Admission.local_deferral(reason) do
          {:rate_limited, seconds, _} when seconds in 1..5 ->
            Process.sleep(seconds * 1_000)
            read_probe(read, retries - 1)

          _ ->
            result
        end

      _ ->
        result
    end
  end

  defp access_failure(reason) do
    retry_after =
      case PeriodicJobs.retry_after_seconds_for(reason) do
        {:ok, seconds} -> seconds
        :none -> nil
      end

    local =
      case Admission.local_deferral(reason) do
        {:rate_limited, _, kind} -> Atom.to_string(kind)
        _ -> nil
      end

    %{
      "status" => "access_failed",
      "failure" => Maraithon.Redaction.error_class(reason),
      "retry_after_seconds" => retry_after,
      "local_deferral" => local
    }
  end
end
