defmodule Maraithon.SecretRef do
  @moduledoc """
  Resolves boot-time secret references and emits redacted runtime snapshots.

  Supported references:

    * `env:VARIABLE_NAME`
    * `file:/absolute/path`
    * `exec:/absolute/provider --optional args`

  `exec:` references are disabled unless their executable path is present in the
  configured or call-site allowlist. They never run through a shell.
  """

  @type ref :: binary()
  @type parsed_ref :: %{kind: binary(), source: binary(), raw_ref: binary()}

  alias Maraithon.Normalization

  def resolve(ref, opts \\ [])

  def resolve(ref, opts) when is_binary(ref) and is_list(opts) do
    with {:ok, parsed} <- parse(ref),
         {:ok, value} <- resolve_parsed(parsed, opts) do
      {:ok,
       parsed
       |> Map.put(:status, "resolved")
       |> Map.put(:value, value)
       |> Map.put(:byte_size, byte_size(value))
       |> Map.put(:fingerprint, fingerprint(value))}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve(_ref, _opts), do: {:error, :invalid_secret_ref}

  def resolve_map(refs, opts \\ [])

  def resolve_map(refs, opts) when is_map(refs) and is_list(opts) do
    refs
    |> Normalization.stringify_keys()
    |> Map.new(fn {name, ref} -> {name, resolve_ref_value(ref, opts)} end)
  end

  def resolve_map(_refs, _opts), do: %{}

  def runtime_snapshot(opts \\ []) when is_list(opts) do
    :maraithon
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:surfaces, %{})
    |> snapshot(opts)
  end

  def snapshot(surfaces, opts \\ []) when is_list(opts) do
    surfaces
    |> normalize_surfaces()
    |> Map.new(fn {surface, refs} ->
      entries =
        refs
        |> normalize_refs()
        |> Enum.map(fn {name, ref} -> redacted_entry(name, ref, opts) end)

      {surface, entries}
    end)
  end

  def redacted_snapshot(snapshot) when is_map(snapshot) do
    Map.new(snapshot, fn {surface, entries} ->
      entries =
        entries
        |> List.wrap()
        |> Enum.map(&redact_entry/1)

      {to_string(surface), entries}
    end)
  end

  def redacted_snapshot(_snapshot), do: %{}

  def validate_active_surfaces(surfaces_or_snapshot, active_surfaces, opts \\ [])
      when is_list(opts) do
    snapshot =
      if snapshot?(surfaces_or_snapshot) do
        redacted_snapshot(surfaces_or_snapshot)
      else
        snapshot(surfaces_or_snapshot, opts)
      end

    findings =
      active_surfaces
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.flat_map(fn surface ->
        case Map.get(snapshot, surface, []) do
          [] ->
            [
              %{
                surface: surface,
                status: "missing",
                reason_code: "missing_secret_refs"
              }
            ]

          entries ->
            entries
            |> Enum.reject(
              &(Map.get(&1, :status) == "resolved" or Map.get(&1, "status") == "resolved")
            )
            |> Enum.map(fn entry ->
              %{
                surface: surface,
                name: Map.get(entry, :name) || Map.get(entry, "name"),
                status: Map.get(entry, :status) || Map.get(entry, "status"),
                reason_code: Map.get(entry, :reason_code) || Map.get(entry, "reason_code")
              }
            end)
        end
      end)

    result = %{status: if(findings == [], do: "ok", else: "blocked"), findings: findings}
    if findings == [], do: {:ok, result}, else: {:error, result}
  end

  def parse(ref) when is_binary(ref) do
    case String.split(ref, ":", parts: 2) do
      ["env", source] -> parse_source("env", source, ref)
      ["file", source] -> parse_source("file", source, ref)
      ["exec", source] -> parse_source("exec", source, ref)
      _ -> {:error, :unsupported_secret_ref}
    end
  end

  def parse(_ref), do: {:error, :invalid_secret_ref}

  defp parse_source(kind, source, raw_ref) do
    source = String.trim(source)

    if source == "" do
      {:error, :invalid_secret_ref_source}
    else
      {:ok, %{kind: kind, source: source, raw_ref: raw_ref}}
    end
  end

  defp resolve_ref_value(ref, opts) when is_binary(ref) do
    case resolve(ref, opts) do
      {:ok, resolved} -> {:ok, Map.fetch!(resolved, :value)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_ref_value(refs, opts) when is_map(refs), do: {:ok, resolve_map(refs, opts)}
  defp resolve_ref_value(_ref, _opts), do: {:error, :invalid_secret_ref}

  defp resolve_parsed(%{kind: "env", source: variable}, _opts) do
    case System.get_env(variable) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_env, variable}}
    end
  end

  defp resolve_parsed(%{kind: "file", source: path}, _opts) do
    case File.read(path) do
      {:ok, value} -> {:ok, String.trim_trailing(value)}
      {:error, reason} -> {:error, {:file_read_failed, path, reason}}
    end
  end

  defp resolve_parsed(%{kind: "exec", source: command}, opts) do
    case split_exec(command) do
      [] ->
        {:error, :invalid_exec_ref}

      [executable | args] ->
        if executable in exec_allowlist(opts) do
          case System.cmd(executable, args, stderr_to_stdout: true) do
            {value, 0} -> {:ok, String.trim_trailing(value)}
            {_value, status} -> {:error, {:exec_failed, executable, status}}
          end
        else
          {:error, {:exec_not_allowed, executable}}
        end
    end
  end

  defp split_exec(command) when is_binary(command) do
    command
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
  end

  defp exec_allowlist(opts) do
    configured =
      :maraithon
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:exec_allowlist, [])

    opts
    |> Keyword.get(:exec_allowlist, configured)
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  defp redacted_entry(name, ref, opts) when is_binary(ref) do
    parsed = parse(ref)

    case {parsed, resolve(ref, opts)} do
      {{:ok, parsed_ref}, {:ok, resolved}} ->
        %{
          name: to_string(name),
          kind: parsed_ref.kind,
          source: source_label(parsed_ref),
          status: "resolved",
          byte_size: resolved.byte_size,
          fingerprint: resolved.fingerprint
        }

      {{:ok, parsed_ref}, {:error, reason}} ->
        %{
          name: to_string(name),
          kind: parsed_ref.kind,
          source: source_label(parsed_ref),
          status: status_for_error(reason),
          reason_code: reason_code(reason)
        }

      {{:error, reason}, _} ->
        %{
          name: to_string(name),
          kind: "unknown",
          source: nil,
          status: "invalid",
          reason_code: reason_code(reason)
        }
    end
  end

  defp redacted_entry(name, refs, opts) when is_map(refs) do
    %{
      name: to_string(name),
      kind: "group",
      source: nil,
      status: "group",
      refs:
        refs
        |> normalize_refs()
        |> Enum.map(fn {nested_name, nested_ref} ->
          redacted_entry(nested_name, nested_ref, opts)
        end)
    }
  end

  defp redacted_entry(name, _ref, _opts) do
    %{
      name: to_string(name),
      kind: "unknown",
      source: nil,
      status: "invalid",
      reason_code: "invalid_secret_ref"
    }
  end

  defp redact_entry(entry) when is_map(entry) do
    entry
    |> Map.drop([:value, "value"])
    |> Map.new(fn {key, value} ->
      value =
        case key do
          :refs -> Enum.map(List.wrap(value), &redact_entry/1)
          "refs" -> Enum.map(List.wrap(value), &redact_entry/1)
          _ -> value
        end

      {key, value}
    end)
  end

  defp redact_entry(_entry), do: %{}

  defp source_label(%{kind: "env", source: source}), do: source
  defp source_label(%{kind: "file", source: source}), do: source

  defp source_label(%{kind: "exec", source: source}) do
    source
    |> split_exec()
    |> List.first()
  end

  defp fingerprint(value) when is_binary(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end

  defp status_for_error({:missing_env, _variable}), do: "missing"
  defp status_for_error(_reason), do: "error"

  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code({reason, _}), do: reason_code(reason)
  defp reason_code({reason, _, _}), do: reason_code(reason)
  defp reason_code(reason), do: inspect(reason)

  defp normalize_surfaces(surfaces) when is_map(surfaces),
    do: Normalization.stringify_keys(surfaces)

  defp normalize_surfaces(_surfaces), do: %{}

  defp normalize_refs(refs) when is_map(refs), do: Normalization.stringify_keys(refs)
  defp normalize_refs(ref) when is_binary(ref), do: %{"default" => ref}
  defp normalize_refs(_refs), do: %{}

  defp snapshot?(value) when is_map(value) do
    Enum.any?(value, fn {_surface, entries} ->
      entries
      |> List.wrap()
      |> Enum.any?(&(is_map(&1) and (Map.has_key?(&1, :status) or Map.has_key?(&1, "status"))))
    end)
  end

  defp snapshot?(_value), do: false
end
