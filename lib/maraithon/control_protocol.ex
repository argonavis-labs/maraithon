defmodule Maraithon.ControlProtocol do
  @moduledoc """
  JSON-RPC control protocol for first-party operator clients.
  """

  alias Maraithon.Agents
  alias Maraithon.Capabilities
  alias Maraithon.ControlCalls
  alias Maraithon.Health
  alias Maraithon.MobileNodes
  alias Maraithon.Normalization
  alias Maraithon.ScheduledTasks
  alias Maraithon.ToolPolicy
  alias Maraithon.Tools

  @version "2026-05-10"
  @max_payload_bytes 256 * 1024

  @methods %{
    "connect" => %{roles: ["operator"], scopes: ["control:read"]},
    "health" => %{roles: ["operator"], scopes: ["control:read"]},
    "status" => %{roles: ["operator"], scopes: ["control:read"]},
    "tools.list" => %{roles: ["operator"], scopes: ["tools:read"]},
    "tools.call" => %{roles: ["operator"], scopes: ["tools:call"]},
    "agents.list" => %{roles: ["operator"], scopes: ["agents:read"]},
    "agents.inspect" => %{roles: ["operator"], scopes: ["agents:read"]},
    "scheduled_tasks.list" => %{roles: ["operator"], scopes: ["scheduled_tasks:read"]},
    "scheduled_tasks.create" => %{roles: ["operator"], scopes: ["scheduled_tasks:write"]},
    "mobile_nodes.commands" => %{roles: ["operator"], scopes: ["mobile_nodes:read"]},
    "mobile_nodes.pair" => %{roles: ["operator"], scopes: ["mobile_nodes:write"]},
    "events.subscribe" => %{roles: ["operator"], scopes: ["events:read"]}
  }

  def max_payload_bytes, do: @max_payload_bytes

  def contract do
    %{
      protocol: "maraithon.control",
      version: @version,
      transport: "json-rpc-2.0/http",
      payload_policy: payload_policy(),
      standard_error: %{
        code: "integer",
        message: "safe string",
        data: "redacted object"
      },
      methods: @methods
    }
  end

  def response_for(%{"jsonrpc" => "2.0", "method" => method} = request) do
    id = Map.get(request, "id")

    case dispatch(method, Map.get(request, "params", %{}), request) do
      {:ok, result} ->
        %{"jsonrpc" => "2.0", "id" => id, "result" => result}

      {:error, code, message, data} ->
        error_response(id, code, message, data)
    end
  end

  def response_for(_request), do: error_response(nil, -32600, "Invalid JSON-RPC request", nil)

  defp dispatch("connect", params, _request) do
    {:ok,
     %{
       protocol: "maraithon.control",
       version: @version,
       connection_id: read_string(params, "connection_id") || Ecto.UUID.generate(),
       contract: contract()
     }}
  end

  defp dispatch("health", _params, _request), do: {:ok, Health.check()}

  defp dispatch("status", _params, _request) do
    {:ok,
     %{
       app: "maraithon",
       version: app_version(),
       protocol_version: @version,
       capabilities: %{
         tools: length(Capabilities.list_capabilities(:tool)),
         connectors: length(Capabilities.list_capabilities(:connector)),
         providers: length(Capabilities.list_capabilities(:provider))
       }
     }}
  end

  defp dispatch("tools.list", params, _request) do
    names = if is_map(params), do: Map.get(params, "names"), else: nil
    {:ok, %{"tools" => Enum.map(Tools.describe(names), &tool_descriptor/1)}}
  end

  defp dispatch("tools.call", %{"name" => name} = params, request) when is_binary(name) do
    arguments = Map.get(params, "arguments", %{})
    idempotency_key = read_string(params, "idempotency_key")
    user_id = read_string(params, "user_id") || read_string(arguments, "user_id")
    metadata = Capabilities.policy_metadata_for(name)

    with true <- is_map(arguments) || {:error, -32602, "Action details must be an object", nil},
         :ok <- require_idempotency_for_side_effect(name, metadata, idempotency_key) do
      ControlCalls.run(
        %{
          method: "tools.call:#{name}",
          idempotency_key: idempotency_key,
          user_id: user_id,
          request: request
        },
        fn ->
          execute_tool_call(name, arguments, params, metadata)
        end
      )
      |> control_call_response()
    else
      {:error, code, message, data} -> {:error, code, message, data}
    end
  end

  defp dispatch("tools.call", _params, _request),
    do: {:error, -32602, "Tool name is required", nil}

  defp dispatch("agents.list", params, _request) do
    user_id = read_string(params, "user_id")

    agents =
      Agents.list_agents(user_id: user_id)
      |> Enum.map(&serialize_agent/1)

    {:ok, %{agents: agents, count: length(agents)}}
  end

  defp dispatch("agents.inspect", %{"agent_id" => agent_id}, _request)
       when is_binary(agent_id) do
    case Agents.get_agent(agent_id, preload: [:project]) do
      nil -> {:error, -32044, "Automation not found", nil}
      agent -> {:ok, %{agent: serialize_agent(agent)}}
    end
  end

  defp dispatch("agents.inspect", _params, _request),
    do: {:error, -32602, "agent_id is required", nil}

  defp dispatch("scheduled_tasks.list", params, _request) do
    user_id = read_string(params, "user_id")

    if user_id do
      tasks =
        user_id
        |> ScheduledTasks.list_tasks(limit: 100)
        |> Enum.map(&ScheduledTasks.serialize_task/1)
        |> normalize()

      {:ok, %{"tasks" => tasks, "count" => length(tasks)}}
    else
      {:error, -32602, "user_id is required", nil}
    end
  end

  defp dispatch("scheduled_tasks.create", params, request) do
    user_id = read_string(params, "user_id")
    idempotency_key = read_string(params, "idempotency_key")
    task_attrs = Map.get(params, "task", params)

    with true <- is_binary(user_id) || {:error, -32602, "user_id is required", nil},
         true <-
           is_binary(idempotency_key) ||
             {:error, -32072, "idempotency_key is required for scheduled_tasks.create", nil},
         true <- is_map(task_attrs) || {:error, -32602, "task must be an object", nil} do
      ControlCalls.run(
        %{
          method: "scheduled_tasks.create",
          idempotency_key: idempotency_key,
          user_id: user_id,
          request: request
        },
        fn ->
          case ScheduledTasks.create_task(user_id, task_attrs) do
            {:ok, task} ->
              {:ok, %{"task" => task |> ScheduledTasks.serialize_task() |> normalize()}}

            {:error, reason} ->
              {:error,
               %{
                 "code" => "scheduled_task_error",
                 "message" => scheduled_task_error_message(reason)
               }}
          end
        end
      )
      |> control_call_response()
    else
      {:error, code, message, data} -> {:error, code, message, data}
    end
  end

  defp dispatch("mobile_nodes.commands", _params, _request) do
    {:ok, MobileNodes.command_contract() |> normalize()}
  end

  defp dispatch("mobile_nodes.pair", params, request) do
    user_id = read_string(params, "user_id")
    idempotency_key = read_string(params, "idempotency_key")

    with true <- is_binary(user_id) || {:error, -32602, "user_id is required", nil},
         true <-
           is_binary(idempotency_key) ||
             {:error, -32072, "idempotency_key is required for mobile_nodes.pair", nil} do
      opts =
        [
          metadata: Map.get(params, "metadata", %{})
        ]
        |> maybe_put_opt(:allowed_commands, read_list_if_present(params, "allowed_commands"))
        |> maybe_put_opt(:ttl_seconds, read_integer(params, "ttl_seconds"))

      ControlCalls.run(
        %{
          method: "mobile_nodes.pair",
          idempotency_key: idempotency_key,
          user_id: user_id,
          request: request
        },
        fn ->
          case MobileNodes.create_pairing(user_id, opts) do
            {:ok, %{pairing: pairing, code: code, expires_at: expires_at}} ->
              {:ok,
               %{
                 "pairing" => pairing |> MobileNodes.redacted_pairing() |> normalize(),
                 "code" => code,
                 "expires_at" => DateTime.to_iso8601(expires_at)
               }}

            {:error, reason} ->
              {:error,
               %{
                 "code" => "mobile_pairing_error",
                 "message" => mobile_pairing_error_message(reason)
               }}
          end
        end
      )
      |> control_call_response()
    else
      {:error, code, message, data} -> {:error, code, message, data}
    end
  end

  defp dispatch("events.subscribe", params, _request) do
    topics = params |> read_list("topics") |> Enum.take(20)

    {:ok,
     %{
       status: "accepted",
       mode: "snapshot",
       topics: topics,
       message:
         "HTTP control protocol accepted the subscription request; stream delivery is not held open on this endpoint."
     }}
  end

  defp dispatch(method, _params, _request),
    do: {:error, -32601, "Method not found: #{method}", nil}

  defp execute_tool_call(name, arguments, params, metadata) do
    context = %{
      surface: "control",
      confirmed?: truthy?(Map.get(params, "confirmed")),
      user_id: read_string(params, "user_id") || read_string(arguments, "user_id"),
      source_context: %{"control_method" => "tools.call"},
      tool_metadata: metadata
    }

    case Tools.execute(name, arguments, context) do
      {:ok, result} ->
        {:ok, %{"result" => normalize(result), "is_error" => false}}

      {:error, {:tool_policy_denied, decision}} ->
        {:error, policy_error("tool_policy_denied", decision)}

      {:error, {:tool_policy_needs_confirmation, decision}} ->
        {:error, policy_error("tool_policy_needs_confirmation", decision)}

      {:error, reason} ->
        {:error, %{"code" => "tool_error", "message" => tool_error_message(reason)}}
    end
  end

  defp require_idempotency_for_side_effect(name, metadata, idempotency_key) do
    if ToolPolicy.material_side_effect?(metadata || %{side_effect: "read"}) and
         is_nil(idempotency_key) do
      {:error, -32072, "A safety key is required before running an action that changes data.",
       %{"tool" => name}}
    else
      :ok
    end
  end

  defp control_call_response({:ok, result, replay?: replay?}) do
    {:ok, Map.put(result, "idempotency_replay", replay?)}
  end

  defp control_call_response(
         {:error, %{"code" => "tool_policy_denied"} = error, replay?: replay?}
       ) do
    {:error, -32070, error["message"] || "Action is not allowed.",
     Map.put(error, "idempotency_replay", replay?)}
  end

  defp control_call_response(
         {:error, %{"code" => "tool_policy_needs_confirmation"} = error, replay?: replay?}
       ) do
    {:error, -32071, error["message"] || "Action requires confirmation.",
     Map.put(error, "idempotency_replay", replay?)}
  end

  defp control_call_response({:error, :idempotency_key_conflict, replay?: _replay?}) do
    {:error, -32073, "idempotency_key was reused with a different payload", nil}
  end

  defp control_call_response({:error, :idempotency_key_in_progress, replay?: _replay?}) do
    {:error, -32074, "idempotency_key is already in progress", nil}
  end

  defp control_call_response({:error, error, replay?: replay?}) when is_map(error) do
    {:ok, %{"is_error" => true, "error" => Map.put(error, "idempotency_replay", replay?)}}
  end

  defp control_call_response({:error, error, replay?: replay?}) do
    {:ok,
     %{
       "is_error" => true,
       "error" => %{
         "message" => control_error_message(error),
         "idempotency_replay" => replay?
       }
     }}
  end

  defp policy_error(code, decision) do
    decision = safe_policy_decision(decision)

    %{
      "code" => code,
      "message" => Map.get(decision, "message", "Maraithon blocked this action."),
      "policy_decision" => decision
    }
  end

  defp safe_policy_decision(decision) when is_map(decision) do
    decision = normalize_map_keys(decision)

    case Map.get(decision, "reason_code") do
      "unknown_tool" ->
        decision
        |> Map.put("message", "Action is not available.")
        |> Map.update("metadata", %{}, fn metadata ->
          metadata
          |> normalize_map_keys()
          |> Map.drop(["tool_name"])
        end)

      _reason_code ->
        decision
    end
  end

  defp safe_policy_decision(_decision) do
    %{"message" => "Maraithon blocked this action.", "reason_code" => "policy_denied"}
  end

  defp scheduled_task_error_message(:missing_title), do: "Scheduled task needs a title."

  defp scheduled_task_error_message(:invalid_schedule),
    do: "Scheduled task needs a valid schedule."

  defp scheduled_task_error_message(:invalid_time), do: "Scheduled task needs a valid time."
  defp scheduled_task_error_message(:invalid_day), do: "Scheduled task needs a valid day."

  defp scheduled_task_error_message(:scheduled_time_in_past),
    do: "Scheduled task time must be in the future."

  defp scheduled_task_error_message(:invalid_command),
    do: "Scheduled task needs a valid command or prompt."

  defp scheduled_task_error_message(%Ecto.Changeset{}),
    do: "Scheduled task could not be saved. Review required fields and try again."

  defp scheduled_task_error_message(_reason),
    do: "Scheduled task could not be created. Review the request and try again."

  defp mobile_pairing_error_message(:forbidden_mobile_command),
    do: "Pairing can only grant supported mobile commands."

  defp mobile_pairing_error_message(:unknown_mobile_command),
    do: "Pairing includes an unsupported mobile command."

  defp mobile_pairing_error_message(:empty_mobile_command_grants),
    do: "Pairing needs at least one supported mobile command."

  defp mobile_pairing_error_message(:invalid_mobile_command_grants),
    do: "Pairing command grants must be a list of supported commands."

  defp mobile_pairing_error_message(:invalid_pairing_expiry),
    do: "Pairing expiration must be between 1 second and 24 hours."

  defp mobile_pairing_error_message(%Ecto.Changeset{}),
    do: "Mobile pairing could not be saved. Review the request and try again."

  defp mobile_pairing_error_message(_reason),
    do: "Mobile pairing could not be created. Review the request and try again."

  defp tool_error_message({:tool_policy_denied, decision}), do: policy_message(decision)

  defp tool_error_message({:tool_policy_needs_confirmation, decision}),
    do: policy_message(decision)

  defp tool_error_message(reason) when is_binary(reason) do
    cond do
      String.ends_with?(reason, "_not_connected") ->
        "Connect the missing account before running this action."

      String.ends_with?(reason, "_reauth_required") or
          String.ends_with?(reason, "_reconnect_required") ->
        "Reconnect the account before running this action."

      String.starts_with?(reason, "missing_") ->
        "Required action details are missing."

      String.ends_with?(reason, "_not_found") ->
        "Requested item was not found."

      String.starts_with?(reason, "unknown_tool:") ->
        "Action is not available."

      String.contains?(reason, ":") ->
        "Action did not complete. No confirmed change was recorded."

      Regex.match?(~r/^[a-z0-9_]+$/, reason) ->
        "Action did not complete. No confirmed change was recorded."

      true ->
        "Action did not complete. No confirmed change was recorded."
    end
  end

  defp tool_error_message(_reason),
    do: "Action did not complete. No confirmed change was recorded."

  defp policy_message(decision) do
    decision
    |> safe_policy_decision()
    |> Map.get("message", "Maraithon blocked this action.")
  end

  defp control_error_message(:idempotency_key_conflict),
    do: "idempotency_key was reused with a different payload"

  defp control_error_message(:idempotency_key_in_progress),
    do: "idempotency_key is already in progress"

  defp control_error_message(%{"message" => message}) when is_binary(message), do: message
  defp control_error_message(%{message: message}) when is_binary(message), do: message
  defp control_error_message(_error), do: "Control action could not be completed. Try again."

  defp tool_descriptor(%{
         name: name,
         description: description,
         input_schema: input_schema,
         annotations: annotations
       }) do
    %{
      "name" => name,
      "description" => description,
      "inputSchema" => input_schema,
      "annotations" => annotations
    }
  end

  defp serialize_agent(agent) do
    %{
      "id" => agent.id,
      "user_id" => agent.user_id,
      "behavior" => agent.behavior,
      "status" => agent.status,
      "install_status" => agent.install_status,
      "name" => get_in(agent.config || %{}, ["name"]),
      "project_id" => agent.project_id,
      "project_name" => project_name(agent),
      "updated_at" => agent.updated_at && DateTime.to_iso8601(agent.updated_at)
    }
  end

  defp project_name(%{project: %{name: name}}), do: name
  defp project_name(_agent), do: nil

  defp error_response(id, code, message, data) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => Normalization.compact(%{"code" => code, "message" => message, "data" => data})
    }
  end

  defp payload_policy do
    %{
      max_bytes: @max_payload_bytes,
      idempotency_required_for: ["write", "destructive", "external_send", "credential", "system"]
    }
  end

  defp normalize(value), do: Normalization.normalize_json_value(value)

  defp normalize_map_keys(map) when is_map(map), do: Normalization.stringify_keys(map)
  defp normalize_map_keys(_value), do: %{}

  defp read_string(map, key), do: Normalization.read_string(map, key)

  defp read_list(map, key), do: Normalization.read_list(map, key)

  defp read_list_if_present(map, key), do: Normalization.read_list_if_present(map, key)

  defp read_integer(map, key), do: Normalization.read_integer(map, key)

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp app_version do
    Application.spec(:maraithon, :vsn)
    |> to_string()
  end
end
