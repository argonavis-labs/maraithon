defmodule Maraithon.Todos.BriefActions do
  @moduledoc """
  Turns a brief's reply into a connected send from the web todo page.

  Reuses the mobile prepared-action pipeline end to end: the todo chat primer
  resolves the draft into a `gmail_draft_send` or `slack_post` prepared
  action (saving an in-thread Gmail draft along the way), and confirming it
  runs the durable execute path with the user's edits applied under the same
  row lock mobile uses.
  """

  alias Maraithon.AssistantChat
  alias Maraithon.AssistantChat.TodoThreadPrimer
  alias Maraithon.TelegramAssistant.PreparedAction
  alias Maraithon.Todos
  alias Maraithon.Todos.{Brief, Todo}

  require Logger

  @prepare_timeout_ms 20_000
  @connected_channels ~w(gmail slack)

  @type target :: %{
          prepared_action_id: String.t(),
          action_type: String.t(),
          channel: String.t(),
          label: String.t(),
          destination: String.t() | nil,
          subject: String.t() | nil,
          body: String.t() | nil,
          expires_at: DateTime.t() | nil
        }

  @doc """
  Prepares the connected send target for the brief's reply.

  Returns `{:ok, target}` when Gmail or Slack can deliver the reply directly,
  `{:error, :no_reply}` when the brief has no reply, `{:error,
  :unsupported_channel}` for channels without a connected send, and
  `{:error, :no_connected_target}` when the source metadata is not complete
  enough to address the message (the page falls back to Copy / Open).
  """
  @spec prepare_reply(String.t(), Todo.t(), keyword()) :: {:ok, target()} | {:error, term()}
  def prepare_reply(user_id, %Todo{} = todo, opts \\ []) when is_binary(user_id) do
    case Brief.reply(todo) do
      nil ->
        {:error, :no_reply}

      %{"channel" => channel} when channel not in @connected_channels ->
        {:error, :unsupported_channel}

      _reply ->
        timeout_ms = Keyword.get(opts, :prepare_timeout_ms, @prepare_timeout_ms)

        with {:ok, thread} <-
               AssistantChat.get_or_create_todo_thread(user_id, todo.id,
                 prepare_timeout_ms: timeout_ms
               ),
             %PreparedAction{} = prepared_action <-
               TodoThreadPrimer.prepared_action_for(thread, todo) do
          {:ok, target(prepared_action)}
        else
          nil -> {:error, :no_connected_target}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Prepares and sends the brief's reply in one step.

  Preparation is deliberately deferred until the user actually sends: for
  Gmail it writes a real draft into the mailbox, which must not happen just
  because someone opened the todo page.
  """
  def send_reply(user_id, %Todo{} = todo, edits)
      when is_binary(user_id) and is_map(edits) do
    with {:ok, target} <- prepare_reply(user_id, todo) do
      send_prepared_reply(user_id, todo, target.prepared_action_id, edits)
    end
  end

  def send_reply(_user_id, _todo, _edits), do: {:error, :invalid_send}

  @doc """
  Confirms and executes an already prepared reply with the user's final edits.

  On success the mobile pipeline marks the linked todo done; when the brief
  said the reply does not resolve the item, the todo is reopened so the
  remaining work stays visible. Returns `{:ok, %{todo: todo, completed?:
  boolean, target: target}}`.
  """
  def send_prepared_reply(user_id, %Todo{} = todo, prepared_action_id, edits)
      when is_binary(user_id) and is_binary(prepared_action_id) and is_map(edits) do
    attrs = %{"draft_edits" => sanitize_edits(edits)}

    case AssistantChat.decide_prepared_action(user_id, prepared_action_id, :confirm, attrs) do
      {:ok, %{prepared_action: %PreparedAction{status: "executed"} = action}} ->
        completed? = finalize_completion(user_id, todo)

        {:ok,
         %{
           todo: Todos.get_for_user(user_id, todo.id),
           completed?: completed?,
           target: target(action)
         }}

      {:ok, %{prepared_action: %PreparedAction{status: status} = action}} ->
        {:error, {:prepared_action_not_executed, status, action.error}}

      {:error, :prepared_action_expired, _action, _thread} ->
        {:error, :expired}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_send_result, other}}
    end
  end

  def send_prepared_reply(_user_id, _todo, _prepared_action_id, _edits),
    do: {:error, :invalid_send}

  @doc """
  True when the brief's reply can be delivered by a connected account.
  """
  def sendable?(%Todo{} = todo) do
    case Brief.reply(todo) do
      %{"channel" => channel} ->
        channel in @connected_channels and todo.status in ~w(open snoozed)

      _other ->
        false
    end
  end

  def sendable?(_todo), do: false

  @doc "Human label for the send button."
  def send_label("gmail"), do: "Send email"
  def send_label("slack"), do: "Post to Slack"
  def send_label(_channel), do: "Send"

  defp finalize_completion(user_id, %Todo{} = todo) do
    resolves? =
      case Brief.reply(todo) do
        %{"resolves_todo" => true} -> true
        _ -> false
      end

    if resolves? do
      true
    else
      case Todos.update_for_user(user_id, todo.id, %{"status" => "open"},
             actor_type: "user",
             actor_id: user_id,
             actor_label: "User",
             note: "Reply sent from the brief; the remaining work stays open."
           ) do
        {:ok, _todo} ->
          false

        {:error, reason} ->
          Logger.warning("todo brief reopen after send failed",
            todo_id: todo.id,
            reason: inspect(reason)
          )

          true
      end
    end
  end

  defp target(%PreparedAction{} = action) do
    payload = action.payload || %{}
    channel = channel_for(action.action_type)

    %{
      prepared_action_id: action.id,
      action_type: action.action_type,
      channel: channel,
      label: send_label(channel),
      destination: destination(channel, payload),
      subject: read_string(payload, "subject"),
      body: read_string(payload, "body") || read_string(payload, "text"),
      expires_at: action.expires_at
    }
  end

  defp channel_for("slack_post"), do: "slack"
  defp channel_for("gmail_draft_send"), do: "gmail"
  defp channel_for("gmail_send"), do: "gmail"
  defp channel_for(_other), do: nil

  defp destination("slack", payload) do
    case read_string(payload, "channel_name") do
      nil ->
        read_string(payload, "recipient") || read_string(payload, "channel")

      name ->
        if String.starts_with?(name, ["#", "@"]), do: name, else: "#" <> name
    end
  end

  defp destination("gmail", payload), do: read_string(payload, "to")
  defp destination(_channel, _payload), do: nil

  defp sanitize_edits(edits) do
    edits
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.filter(fn {key, value} ->
      key in ["body", "text", "subject", "to", "cc", "bcc"] and is_binary(value) and
        String.trim(value) != ""
    end)
    |> Map.new()
  end

  defp read_string(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp read_string(_map, _key), do: nil
end
