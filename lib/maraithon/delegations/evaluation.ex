defmodule Maraithon.Delegations.Evaluation do
  @moduledoc "The controlled Kent-to-Kent evaluation. Preflight is read-only and never calls a model."
  alias Maraithon.{Accounts, AssistantIdentities, ConnectedAccounts, LLM}
  alias Maraithon.Connectors.GoogleCalendar

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
