defmodule Maraithon.Runtime.Config do
  @moduledoc """
  Runtime configuration helpers with lightweight validation.
  """

  require Logger

  @runtime_key Maraithon.Runtime

  @doc """
  Fetch a raw runtime config value with a default.
  """
  def get(key, default) do
    Application.get_env(:maraithon, @runtime_key, [])
    |> Keyword.get(key, default)
  end

  @doc """
  Fetch a positive integer runtime setting.
  Falls back to default when the value is invalid.
  """
  def positive_integer(key, default) when is_integer(default) and default > 0 do
    value = get(key, default)

    if is_integer(value) and value > 0 do
      value
    else
      Logger.warning("Invalid runtime config; using default", key: key, value: inspect(value))
      default
    end
  end

  @doc """
  Returns whether this revision may participate in the exact Agent runtime.

  This is deliberately fail-closed. Production must enable it only after the
  externally verified non-rolling legacy fleet drain described in the rollout
  runbook; process registries and BootGate are not fleet-absence proof.
  """
  def exact_agent_runtime_enabled? do
    get(:exact_agent_runtime_enabled, false) == true
  end

  @doc """
  Returns whether exact Agent admission has both the revision interlock and the
  authoritative database Effect protocol. A config flag alone never proves a
  stopped-fleet cutover completed.
  """
  def exact_agent_runtime_ready? do
    exact_agent_runtime_enabled?() and
      (Maraithon.Effects.ProtocolCutover.mode() == :exact or test_protocol_bypass?()) and
      coordination_requirement_ready?()
  rescue
    _storage_unavailable -> false
  catch
    :exit, _reason -> false
  end

  defp coordination_requirement_ready? do
    multinode_coordination_ready?() or test_protocol_bypass?()
  end

  if Mix.env() == :test do
    defp test_protocol_bypass? do
      get(:allow_legacy_effect_protocol_in_test, false) == true
    end
  else
    defp test_protocol_bypass?, do: false
  end

  @doc "Returns whether this revision may participate in DB-owned multi-node coordination."
  def multinode_coordination_enabled? do
    get(:multinode_coordination_enabled, false) == true
  end

  @doc "Fails closed unless config, catalog-attested DB mode, and local ready-last session agree."
  def multinode_coordination_ready? do
    multinode_coordination_enabled?() and
      Maraithon.Runtime.Coordination.Protocol.mode() == :active and
      match?({:ok, _session}, Maraithon.Runtime.Coordination.Session.current())
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc """
  Returns absolute allowed tool root directories.
  """
  def tool_allowed_paths do
    get(:tool_allowed_paths, default_tool_roots())
    |> normalize_paths()
  end

  defp normalize_paths(paths) when is_binary(paths) do
    [paths] |> normalize_paths()
  end

  defp normalize_paths(paths) when is_list(paths) do
    paths
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp normalize_paths(_), do: default_tool_roots() |> Enum.map(&Path.expand/1)

  defp default_tool_roots do
    [File.cwd!(), System.tmp_dir!()]
  end
end
