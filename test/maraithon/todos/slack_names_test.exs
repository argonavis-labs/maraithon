defmodule Maraithon.Todos.SlackNamesTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.{Accounts, OAuth, Todos}
  alias Maraithon.Slack.UserDirectory
  alias Maraithon.Todos.{SlackNames, Todo}

  @slack_id "U0A7JQ8V5NH"
  @team "T0B7FA3NVHA"

  setup do
    bypass = Bypass.open()
    previous = Application.get_env(:maraithon, :slack, [])
    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}/api")
    on_exit(fn -> Application.put_env(:maraithon, :slack, previous) end)
    user = "slack-names-#{System.unique_integer([:positive])}@example.com"
    {:ok, _} = Accounts.get_or_create_user_by_email(user)

    {:ok, _} =
      OAuth.store_tokens(user, "slack:#{@team}:user:UKENT", %{
        access_token: "test-reader",
        scopes: ["channels:history"]
      })

    {:ok, _} =
      OAuth.store_tokens(user, "slack:#{@team}", %{
        access_token: "test-directory",
        scopes: ["users:read"]
      })

    %{bypass: bypass, user: user}
  end

  test "bare IDs and mentions become names without changing links or unknown IDs" do
    names = %{@slack_id => "Alex Smith"}
    link = "https://app.slack.com/team/#{@slack_id}"
    text = "Reply to #{@slack_id} and <@#{@slack_id}>; U9999999999 #{link}"

    assert UserDirectory.replace_user_ids(text, names) ==
             "Reply to Alex Smith and @Alex Smith; U9999999999 #{link}"
  end

  test "background repair uses the workspace token with directory permission and preserves routing",
       c do
    expect_name(c.bypass)
    todo = create_todo(c.user)
    assert {:ok, updated} = Todos.resolve_slack_names(todo)
    assert updated.title == "Reply to Alex Smith on Brett note workaround"
    assert updated.counterparty_label == "Alex Smith"
    assert updated.metadata["person"] == "Alex Smith"
    assert updated.action_draft == todo.action_draft
    assert updated.source_item_id == todo.source_item_id
    assert updated.workflow == todo.workflow
    assert updated.status == todo.status
    assert Todos.get_for_user(c.user, todo.id).title == updated.title
    assert Repo.get!(Todo, todo.id).title == updated.title
    assert {:ok, ^updated} = Todos.resolve_slack_names(updated)
  end

  test "a delayed name lookup cannot overwrite a later task edit", c do
    expect_name(c.bypass)
    todo = create_todo(c.user)

    edited =
      todo
      |> Ecto.Changeset.change(
        title: "Already handled",
        updated_at: DateTime.add(todo.updated_at, 1, :second)
      )
      |> Repo.update!()

    assert {:error, :stale_todo} = Todos.resolve_slack_names(todo)
    assert Repo.get!(Todo, todo.id).title == edited.title
  end

  test "names are isolated to the task workspace and failure leaves copy intact", c do
    todo = create_todo(c.user)

    other_team = %{
      todo
      | metadata: Map.put(todo.metadata, "source_ref", "slack:TOTHER:C123:123.456")
    }

    assert SlackNames.changes(other_team) == %{}

    Bypass.expect_once(c.bypass, "GET", "/api/users.info", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"ok":false,"error":"user_not_found"}))
    end)

    assert {:ok, ^todo} = Todos.resolve_slack_names(todo)

    saved = %{
      todo
      | metadata:
          Map.put(other_team.metadata, "slack_user_names", %{
            "team_id" => @team,
            "names" => %{@slack_id => "Wrong workspace"}
          })
    }

    assert SlackNames.directory(saved) == %{}
  end

  defp expect_name(bypass) do
    Bypass.expect_once(bypass, "GET", "/api/users.info", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-directory"]
      assert Plug.Conn.fetch_query_params(conn).params["user"] == @slack_id

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{ok: true, user: %{id: @slack_id, profile: %{display_name: "Alex Smith"}}})
      )
    end)
  end

  defp create_todo(user) do
    {:ok, [todo]} =
      Todos.upsert_many(user, [
        %{
          "source" => "slack",
          "title" => "Reply to #{@slack_id} on Brett note workaround",
          "summary" => "#{@slack_id} asked for an update",
          "next_action" => "Reply in Slack",
          "counterparty_label" => @slack_id,
          "source_item_id" => "C123:123.456",
          "dedupe_key" => "slack-name:#{user}",
          "action_draft" => %{
            "channel" => "slack",
            "to" => @slack_id,
            "text" => "Thanks <@#{@slack_id}>"
          },
          "metadata" => %{"source_ref" => "slack:#{@team}:C123:123.456", "person" => @slack_id}
        }
      ])

    todo
  end
end
