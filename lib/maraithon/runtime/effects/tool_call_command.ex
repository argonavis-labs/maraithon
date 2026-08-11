defmodule Maraithon.Runtime.Effects.ToolCallCommand do
  @moduledoc """
  Command implementation for `tool_call` effects.
  """

  @behaviour Maraithon.Runtime.Effects.Command

  import Ecto.Query

  alias Maraithon.AgentIsolation
  alias Maraithon.AgentIsolation.Binding
  alias Maraithon.Agents
  alias Maraithon.Agents.Agent
  alias Maraithon.Agents.AgentPackageVersion
  alias Maraithon.Effects.Effect
  alias Maraithon.Normalization
  alias Maraithon.Repo
  alias Maraithon.ToolPolicy
  alias Maraithon.ToolPolicy.Decision
  alias Maraithon.Tools

  @prepared_authority_version 1

  @impl true
  def prepare(%Effect{} = effect) do
    context = execution_context(effect)

    with {:ok, tool_module} <- Tools.fetch(context.tool_name),
         {:ok, package_version} <- authorize_package_tool(context.agent, context.tool_name),
         {:ok, decision} <- authorize_policy(context.policy_context) do
      authority_binding =
        prepared_authority_binding(
          effect,
          context,
          package_version,
          tool_module,
          decision
        )

      {:ok,
       %{
         tool_module: tool_module,
         args: context.args,
         policy_context: execution_policy_context(context.policy_context),
         policy_decision: decision,
         authority_binding: authority_binding
       }}
    end
  end

  @impl true
  def execute_prepared(
        %Effect{},
        %{
          tool_module: tool_module,
          args: args,
          policy_context: policy_context,
          policy_decision: %Decision{status: :allow} = decision,
          authority_binding: %{
            version: @prepared_authority_version,
            digest: digest
          }
        }
      )
      when is_atom(tool_module) and is_map(args) and is_map(policy_context) and
             is_binary(digest) and byte_size(digest) == 32 do
    Tools.execute_prepared(tool_module, args, policy_context, decision)
  end

  def execute_prepared(%Effect{}, _prepared), do: {:error, :invalid_tool_preflight}

  @impl true
  def execute(%Effect{} = effect) do
    with {:ok, prepared} <- prepare(effect) do
      execute_prepared(effect, prepared)
    end
  end

  @impl true
  def revalidate_prepared_authority(
        %Effect{} = effect,
        %{
          tool_module: tool_module,
          args: args,
          policy_context: policy_context,
          policy_decision: %Decision{status: :allow} = prepared_decision,
          authority_binding:
            %{
              version: @prepared_authority_version,
              digest: expected_digest
            } = expected_binding
        },
        %{agent: %Agent{} = agent, binding: %Binding{} = binding}
      )
      when is_atom(tool_module) and is_map(args) and is_map(policy_context) and
             is_binary(expected_digest) and byte_size(expected_digest) == 32 do
    tool_name = Map.get(policy_context, :tool_name) || Map.get(policy_context, "tool_name")

    with true <- Repo.in_transaction?(),
         true <- exact_authority_identifiers?(expected_binding, effect, agent, binding),
         {:ok, ^tool_module} <- Tools.fetch(tool_name),
         {:ok, package_version} <- lock_authorized_package_tool(agent, tool_name),
         current_policy_context <- locked_policy_context(policy_context, agent, binding),
         {:ok, current_decision} <- authorize_policy(current_policy_context),
         true <- Decision.to_map(prepared_decision) == Decision.to_map(current_decision),
         current_digest <-
           authorization_digest(
             effect,
             agent,
             binding,
             package_version,
             tool_module,
             args,
             current_policy_context,
             current_decision
           ),
         true <- current_digest == expected_digest do
      :ok
    else
      _drifted_or_invalid -> {:error, :stale_effect_context}
    end
  end

  def revalidate_prepared_authority(%Effect{}, _prepared, _locked_authority),
    do: {:error, :stale_effect_context}

  defp execution_context(%Effect{} = effect) do
    tool_name = if is_map(effect.params), do: effect.params["tool"]

    agent =
      case effect.agent_id do
        agent_id when is_binary(agent_id) and agent_id != "" ->
          Agents.get_agent(agent_id, include_removed: true)

        _ ->
          nil
      end

    binding = execution_binding(effect, agent)
    user_id = trusted_effect_user_id(effect, agent)
    raw_args = if is_map(effect.params), do: effect.params["args"]
    args = bind_user_id(raw_args, user_id)

    policy_context = %{
      surface: "runtime",
      agent_id: effect.agent_id,
      user_id: user_id,
      confirmed?: is_map(effect.params) and effect.params["confirmed"] == true,
      confirmation_state: if(is_map(effect.params), do: effect.params["confirmation_state"]),
      tool_name: tool_name,
      arguments: args,
      tool_metadata: Tools.policy_metadata_for(tool_name),
      agent_policy: binding_tool_policy(binding)
    }

    %{
      agent: agent,
      binding: binding,
      tool_name: tool_name,
      args: args,
      policy_context: policy_context
    }
  end

  defp authorize_policy(policy_context) do
    case ToolPolicy.authorize(policy_context) do
      %Decision{status: :allow} = decision ->
        {:ok, decision}

      %Decision{status: :deny} = decision ->
        {:error, {:tool_policy_denied, Decision.to_map(decision)}}

      %Decision{status: :needs_confirmation} = decision ->
        {:error, {:tool_policy_needs_confirmation, Decision.to_map(decision)}}
    end
  end

  defp authorize_package_tool(nil, _tool_name), do: {:ok, nil}
  defp authorize_package_tool(%Agent{agent_package_version_id: nil}, _tool_name), do: {:ok, nil}

  defp authorize_package_tool(%Agent{agent_package_version_id: version_id} = agent, tool_name)
       when is_binary(version_id) and is_binary(tool_name) do
    agent
    |> package_version_for_agent()
    |> authorize_package_version(agent, tool_name)
  end

  defp authorize_package_tool(_agent, _tool_name), do: {:error, :tool_not_allowed}

  defp lock_authorized_package_tool(
         %Agent{agent_package_version_id: nil},
         _tool_name
       ),
       do: {:ok, nil}

  # Final entry already owns Agent -> Binding and lifecycle locks. Package
  # writers either own only this version row or Package -> version; none waits
  # back on Agent/Binding, so taking the version lock here preserves the
  # canonical order without adding a Package/version inversion.
  defp lock_authorized_package_tool(
         %Agent{agent_package_version_id: version_id} = agent,
         tool_name
       )
       when is_binary(version_id) and is_binary(tool_name) do
    version =
      Repo.one(
        from(version in AgentPackageVersion,
          where: version.id == ^version_id,
          lock: "FOR UPDATE"
        )
      )

    authorize_package_version(version, agent, tool_name)
  end

  defp lock_authorized_package_tool(_agent, _tool_name),
    do: {:error, :tool_not_allowed}

  defp package_version_for_agent(%Agent{agent_package_version_id: version_id})
       when is_binary(version_id),
       do: Agents.get_agent_package_version(version_id)

  defp authorize_package_version(
         %AgentPackageVersion{
           id: version_id,
           agent_package_id: package_id,
           tool_allowlist: allowlist
         } = version,
         %Agent{
           agent_package_id: package_id,
           agent_package_version_id: version_id
         },
         tool_name
       )
       when is_binary(package_id) and is_list(allowlist) and is_binary(tool_name) do
    if tool_name in allowlist,
      do: {:ok, version},
      else: {:error, :tool_not_allowed}
  end

  defp authorize_package_version(_version, _agent, _tool_name),
    do: {:error, :tool_not_allowed}

  defp prepared_authority_binding(
         effect,
         %{agent: agent, binding: binding, args: args, policy_context: policy_context},
         package_version,
         tool_module,
         decision
       ) do
    %{
      version: @prepared_authority_version,
      digest:
        authorization_digest(
          effect,
          agent,
          binding,
          package_version,
          tool_module,
          args,
          policy_context,
          decision
        ),
      agent_id: authority_id(agent, :id),
      binding_id: authority_id(binding, :id),
      agent_package_id: authority_id(agent, :agent_package_id),
      agent_package_version_id: authority_id(agent, :agent_package_version_id)
    }
  end

  defp authorization_digest(
         effect,
         agent,
         binding,
         package_version,
         tool_module,
         args,
         policy_context,
         decision
       ) do
    material = %{
      "version" => @prepared_authority_version,
      "effect" => %{
        "agent_id" => effect.agent_id,
        "owner_user_id" => effect.owner_user_id
      },
      "agent" => agent_authority_material(agent),
      "binding" => binding_authority_material(binding),
      "package_version" => package_version_authority_material(package_version),
      "tool_module" => Atom.to_string(tool_module),
      "arguments" => Normalization.normalize_json_value(args),
      "policy_context" => Normalization.normalize_json_value(policy_context),
      "policy_decision" => decision |> Decision.to_map() |> Normalization.normalize_json_value()
    }

    :crypto.hash(:sha256, :erlang.term_to_binary(material, [:deterministic]))
  end

  defp agent_authority_material(%Agent{} = agent) do
    %{
      "id" => agent.id,
      "user_id" => agent.user_id,
      "agent_package_id" => agent.agent_package_id,
      "agent_package_version_id" => agent.agent_package_version_id
    }
  end

  defp agent_authority_material(nil), do: nil

  defp binding_authority_material(%Binding{} = binding) do
    %{
      "id" => binding.id,
      "agent_id" => binding.agent_id,
      "user_id" => binding.user_id,
      "status" => binding.status,
      "consent_token" => binding.consent_token,
      "consent_digest" => binding.consent_digest,
      "tool_policy" => Normalization.normalize_json_value(binding.tool_policy || %{})
    }
  end

  defp binding_authority_material(nil), do: nil

  defp package_version_authority_material(%AgentPackageVersion{} = version) do
    %{
      "id" => version.id,
      "agent_package_id" => version.agent_package_id,
      "version" => version.version,
      "status" => version.status,
      "tool_allowlist" => Normalization.normalize_json_value(version.tool_allowlist || []),
      "updated_at" => Normalization.normalize_json_value(version.updated_at)
    }
  end

  defp package_version_authority_material(nil), do: nil

  defp exact_authority_identifiers?(expected, effect, agent, binding) do
    expected.agent_id == agent.id and
      expected.binding_id == binding.id and
      expected.agent_package_id == agent.agent_package_id and
      expected.agent_package_version_id == agent.agent_package_version_id and
      effect.agent_id == agent.id and
      effect.owner_user_id == agent.user_id and
      binding.agent_id == agent.id and
      binding.user_id == agent.user_id and
      binding.status == "active"
  end

  defp locked_policy_context(policy_context, agent, binding) do
    policy_context
    |> Map.drop([:agent_policy, "agent_policy"])
    |> Map.put(:agent_id, agent.id)
    |> Map.put(:user_id, agent.user_id)
    |> Map.put(:agent_policy, binding.tool_policy || %{})
  end

  defp execution_policy_context(policy_context),
    do: Map.drop(policy_context, [:agent_policy, "agent_policy"])

  defp execution_binding(
         %Effect{owner_user_id: user_id},
         %Agent{id: agent_id, user_id: user_id} = agent
       )
       when is_binary(user_id) do
    case AgentIsolation.get_binding(agent) do
      %Binding{
        agent_id: ^agent_id,
        user_id: ^user_id,
        status: "active"
      } = binding ->
        binding

      _missing_or_mismatched ->
        nil
    end
  end

  defp execution_binding(_effect, _agent), do: nil

  defp binding_tool_policy(%Binding{tool_policy: policy}) when is_map(policy), do: policy
  defp binding_tool_policy(_binding), do: %{}

  defp authority_id(authority, field) when is_map(authority), do: Map.get(authority, field)
  defp authority_id(_authority, _field), do: nil

  # Tool arguments originate with the model. Tenant identity only comes from
  # the persisted agent and is shared by both policy enforcement and execution.
  defp bind_user_id(args, user_id) do
    args = if is_map(args), do: Map.drop(args, ["user_id", :user_id]), else: %{}

    if is_binary(user_id), do: Map.put(args, "user_id", user_id), else: args
  end

  defp trusted_effect_user_id(
         %Effect{owner_user_id: owner_user_id},
         %{user_id: owner_user_id, status: status, install_status: install_status}
       )
       when is_binary(owner_user_id) and byte_size(owner_user_id) in 1..255 and
              status in ["running", "degraded"] and install_status == "enabled" do
    if String.valid?(owner_user_id) and String.trim(owner_user_id) != "", do: owner_user_id
  end

  defp trusted_effect_user_id(_effect, _agent), do: nil
end
