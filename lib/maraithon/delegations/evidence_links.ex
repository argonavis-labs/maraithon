defmodule Maraithon.Delegations.EvidenceLinks do
  @moduledoc "Provider links built from saved references and the user's own accounts, without provider I/O."
  import Ecto.Query
  alias Maraithon.{Repo, Accounts.ConnectedAccount}

  def accounts(user_id) do
    Repo.all(
      from a in ConnectedAccount,
        where: a.user_id == ^user_id,
        select: {a.id, a.metadata["account_email"], a.metadata["email"], a.external_account_id}
    )
    |> Map.new(fn {id, account_email, email, external_id} ->
      {id, account_email || email || external_id}
    end)
  end

  def links(refs, accounts, team_id \\ nil) do
    refs |> Enum.flat_map(&link(&1, accounts, team_id)) |> Enum.uniq()
  end

  defp link(ref, accounts, team_id) when is_map(ref) do
    case ref["provider"] || ref["source"] do
      "gmail" ->
        email = accounts[ref["account_id"]]
        id = ref["message_id"] || ref["id"] || ref["thread_id"]

        if is_binary(email) and String.contains?(email, "@") and is_binary(id) and id != "" do
          [
            %{
              label: "Open email",
              url:
                "https://mail.google.com/mail/u/?" <>
                  URI.encode_query(%{"authuser" => email}) <> "#all/" <> URI.encode_www_form(id)
            }
          ]
        else
          []
        end

      "slack" ->
        team = ref["team_id"] || team_id
        channel = ref["channel"]

        if is_binary(team) and is_binary(channel) do
          [
            %{
              label: "Open Slack conversation",
              url:
                "slack://channel?" <>
                  URI.encode_query(%{"team" => team, "id" => channel})
            }
          ]
        else
          []
        end

      _ ->
        []
    end
  end

  defp link(_, _, _), do: []

  def calendar(url) when is_binary(url) do
    case URI.parse(url) do
      %{scheme: "https", host: host, userinfo: nil, path: path}
      when host in ["calendar.google.com", "www.google.com"] and is_binary(path) ->
        if String.starts_with?(path, "/calendar"),
          do: [%{label: "Open calendar event", url: url}],
          else: []

      _ ->
        []
    end
  end

  def calendar(_), do: []
end
