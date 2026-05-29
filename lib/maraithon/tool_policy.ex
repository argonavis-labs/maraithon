defmodule Maraithon.ToolPolicy do
  @moduledoc """
  Authorization gate for model-controlled tool calls and side effects.
  """

  alias Maraithon.ActionLedger
  alias Maraithon.Normalization
  alias Maraithon.ToolPolicy.Decision

  @confirmation_surfaces MapSet.new(~w(telegram mcp runtime agent_harness control))
  @material_side_effects MapSet.new(~w(write destructive external_send credential system))

  def authorize(attrs) when is_map(attrs) do
    context = normalize_context(attrs)
    agent_policy_block = agent_policy_block(context)

    cond do
      context.tool_name in [nil, ""] ->
        deny("missing_tool_name", "Choose an action before continuing.", context)

      not context.known? ->
        deny("unknown_tool", "Action is not available.", context)

      context.user_required? and not valid_user_id?(context.user_id) ->
        deny(
          "invalid_user_context",
          "Sign in again so Maraithon can confirm the account.",
          context
        )

      is_tuple(agent_policy_block) ->
        {reason_code, message} = agent_policy_block
        deny(reason_code, message, context)

      needs_confirmation?(context) ->
        Decision.new(
          :needs_confirmation,
          "confirmation_required",
          "Confirm this action before Maraithon continues.",
          decision_metadata(context)
        )

      true ->
        Decision.new(:allow, "policy_allowed", "Action allowed.", decision_metadata(context))
    end
  end

  def authorize(_attrs), do: deny("invalid_policy_context", "Policy context must be a map.", %{})

  def enforce(attrs, fun) when is_map(attrs) and is_function(fun, 0) do
    if truthy?(read_value(attrs, :policy_checked?)) do
      fun.()
    else
      context = normalize_context(attrs)
      decision = authorize(context)

      case decision.status do
        :allow ->
          result = fun.()
          maybe_record_success(context, decision, result)
          result

        :deny ->
          record_decision(context, decision)
          {:error, {:tool_policy_denied, Decision.to_map(decision)}}

        :needs_confirmation ->
          record_decision(context, decision)
          {:error, {:tool_policy_needs_confirmation, Decision.to_map(decision)}}
      end
    end
  end

  def metadata_for(tool_name) when is_binary(tool_name) do
    case Maraithon.Tools.policy_metadata_for(tool_name) do
      nil -> nil
      metadata -> normalize_metadata(metadata)
    end
  end

  def metadata_for(_tool_name), do: nil

  def material_side_effect?(metadata_or_context) do
    side_effect =
      metadata_or_context
      |> normalize_metadata()
      |> Map.get(:side_effect, "read")

    MapSet.member?(@material_side_effects, side_effect)
  end

  def confirmed?(attrs) when is_map(attrs) do
    truthy?(read_value(attrs, :confirmed?)) or
      read_string(attrs, :confirmation_state) == "confirmed"
  end

  def confirmed?(_attrs), do: false

  def error_message({:tool_policy_denied, %{"message" => message}}), do: message
  def error_message({:tool_policy_needs_confirmation, %{"message" => message}}), do: message
  def error_message({:tool_policy_denied, %{message: message}}), do: message
  def error_message({:tool_policy_needs_confirmation, %{message: message}}), do: message
  def error_message(reason) when is_binary(reason), do: reason
  def error_message(reason), do: inspect(reason)

  defp needs_confirmation?(context) do
    not context.confirmed? and
      MapSet.member?(@confirmation_surfaces, context.surface) and
      context.confirmation_required?
  end

  defp maybe_record_success(context, decision, {:ok, _result}) do
    if MapSet.member?(@material_side_effects, context.side_effect) do
      record_decision(context, decision, status: "completed", event_type: "tool.executed")
    end
  end

  defp maybe_record_success(_context, _decision, _result), do: :ok

  defp record_decision(context, decision, overrides \\ [])

  defp record_decision(%{user_id: nil, agent_id: nil}, _decision, _overrides), do: :ok

  defp record_decision(context, %Decision{} = decision, overrides) do
    status = Keyword.get(overrides, :status, status_for(decision.status))
    event_type = Keyword.get(overrides, :event_type, event_type_for(decision.status))

    attrs = %{
      user_id: context.user_id,
      agent_id: context.agent_id,
      surface: context.surface,
      event_type: event_type,
      status: status,
      source_evidence: context.source_context,
      policy_decision: Decision.to_map(decision),
      confirmation_state: if(decision.status == :needs_confirmation, do: "required", else: nil),
      result_object_refs: %{},
      remediation_hint: remediation_hint(decision),
      metadata: %{
        tool_name: context.tool_name,
        side_effect: context.side_effect,
        argument_keys: argument_keys(context.arguments)
      }
    }

    case ActionLedger.record(attrs) do
      {:ok, _action} -> :ok
      {:error, _reason} -> :ok
    end
  rescue
    _error -> :ok
  end

  defp status_for(:allow), do: "allowed"
  defp status_for(:deny), do: "denied"
  defp status_for(:needs_confirmation), do: "needs_confirmation"

  defp event_type_for(:allow), do: "tool.allowed"
  defp event_type_for(:deny), do: "tool.denied"
  defp event_type_for(:needs_confirmation), do: "tool.needs_confirmation"

  defp remediation_hint(%Decision{status: :needs_confirmation}) do
    "Ask the user to confirm before executing this action."
  end

  defp remediation_hint(%Decision{status: :deny, reason_code: "invalid_user_context"}) do
    "Pass a valid user_id in the policy context or tool arguments."
  end

  defp remediation_hint(%Decision{status: :deny, reason_code: "unknown_tool"}) do
    "Use a registered tool name."
  end

  defp remediation_hint(%Decision{status: :deny, reason_code: reason_code})
       when reason_code in ["agent_tool_denied", "agent_tool_not_allowed"] do
    "Update the agent action allowlist or use an allowed action."
  end

  defp remediation_hint(_decision), do: nil

  defp deny(reason_code, message, context) do
    Decision.new(:deny, reason_code, message, decision_metadata(normalize_context(context)))
  end

  defp normalize_context(%{} = attrs) do
    tool_name = read_string(attrs, :tool_name) || read_string(attrs, :name)
    explicit_metadata = read_value(attrs, :tool_metadata) || read_value(attrs, :metadata)
    raw_metadata = explicit_metadata || metadata_for(tool_name)

    known? =
      case read_value(attrs, :known?) do
        nil -> is_map(raw_metadata) and map_size(raw_metadata) > 0
        value -> truthy?(value)
      end

    metadata = normalize_metadata(raw_metadata)
    arguments = read_map(attrs, :arguments)
    user_id = read_string(attrs, :user_id) || read_string(arguments, :user_id)

    %{
      user_id: user_id,
      agent_id: read_string(attrs, :agent_id),
      surface: read_string(attrs, :surface, "internal"),
      tool_name: tool_name,
      arguments: arguments,
      side_effect: read_string(attrs, :side_effect) || Map.get(metadata, :side_effect, "read"),
      source_context: read_map(attrs, :source_context),
      confirmed?: confirmed?(attrs),
      known?: known?,
      user_required?: Map.get(metadata, :user_required?, false),
      confirmation_required?: Map.get(metadata, :confirmation_required?, false),
      agent_policy: read_map(attrs, :agent_policy),
      metadata: metadata
    }
  end

  defp normalize_context(_attrs) do
    %{
      user_id: nil,
      agent_id: nil,
      surface: "internal",
      tool_name: nil,
      arguments: %{},
      side_effect: "read",
      source_context: %{},
      confirmed?: false,
      known?: false,
      user_required?: false,
      confirmation_required?: false,
      agent_policy: %{},
      metadata: %{}
    }
  end

  defp normalize_metadata(nil), do: %{}

  defp normalize_metadata(metadata) when is_map(metadata) do
    %{
      side_effect: read_string(metadata, :side_effect, "read"),
      user_required?: truthy?(read_value(metadata, :user_required?)),
      confirmation_required?: truthy?(read_value(metadata, :confirmation_required?)),
      read_only?: truthy?(read_value(metadata, :read_only?)),
      destructive?: truthy?(read_value(metadata, :destructive?)),
      idempotent?: truthy?(read_value(metadata, :idempotent?))
    }
  end

  defp normalize_metadata(_metadata), do: %{}

  defp decision_metadata(context) when is_map(context) do
    %{
      tool_name: Map.get(context, :tool_name),
      surface: Map.get(context, :surface),
      side_effect: Map.get(context, :side_effect),
      user_required: Map.get(context, :user_required?),
      confirmation_required: Map.get(context, :confirmation_required?),
      agent_policy_applied: Map.get(context, :agent_policy, %{}) != %{}
    }
  end

  defp agent_policy_block(%{agent_policy: policy, tool_name: tool_name})
       when is_map(policy) and is_binary(tool_name) do
    policy = stringify_keys(policy)
    denied_tools = policy |> Map.get("denied_tools", []) |> normalize_string_list()
    allowed_tools = policy |> Map.get("allowed_tools", []) |> normalize_string_list()

    cond do
      tool_name in denied_tools ->
        {"agent_tool_denied", "This agent is not allowed to use that action."}

      allowed_tools != [] and tool_name not in allowed_tools ->
        {"agent_tool_not_allowed", "This agent is not allowed to use that action."}

      true ->
        nil
    end
  end

  defp agent_policy_block(_context), do: nil

  defp read_value(attrs, key) when is_map(attrs) and is_atom(key),
    do: attrs |> Normalization.stringify_keys() |> Map.get(Atom.to_string(key))

  defp read_value(_attrs, _key), do: nil

  defp read_string(attrs, key, default \\ nil),
    do: Normalization.read_string(attrs, key, default)

  defp read_map(attrs, key), do: Normalization.read_map(attrs, key)

  defp valid_user_id?(user_id) when is_binary(user_id), do: String.trim(user_id) != ""
  defp valid_user_id?(_user_id), do: false

  defp truthy?(value) when value in [true, "true", "1", 1, true], do: true
  defp truthy?(_value), do: false

  defp normalize_string_list(value), do: Normalization.string_list(value)

  defp stringify_keys(value), do: Normalization.stringify_keys(value)

  defp argument_keys(arguments) when is_map(arguments) do
    arguments
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp argument_keys(_arguments), do: []
end
