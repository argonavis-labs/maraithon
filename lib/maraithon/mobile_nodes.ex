defmodule Maraithon.MobileNodes do
  @moduledoc """
  Narrow mobile/node pairing and command authorization.

  V1 intentionally exposes only bounded commands. There is no shell, file
  write, general remote execution, or arbitrary tool-call command.
  """

  import Ecto.Query

  alias Maraithon.ActionLedger
  alias Maraithon.MobileNodes.{Device, Pairing}
  alias Maraithon.Repo

  @allowed_commands ~w(notify open_url capture_text device_status)
  @forbidden_commands ~w(exec shell file_write file_read remote_tool_call tool_call eval system_cmd)
  @default_pairing_ttl_seconds 10 * 60
  @default_limit 50
  @max_limit 200

  def command_contract do
    %{
      allowed_commands: @allowed_commands,
      forbidden_commands: @forbidden_commands,
      execution_model: "narrow_device_command_only",
      remote_execution: false
    }
  end

  def create_pairing(user_id, opts \\ [])

  def create_pairing(user_id, opts) when is_binary(user_id) and is_list(opts) do
    with {:ok, commands} <- normalize_allowed_commands(Keyword.get(opts, :allowed_commands)),
         {:ok, expires_at} <- pairing_expiry(opts) do
      code = generate_pairing_code()
      nonce = :crypto.strong_rand_bytes(16)

      attrs = %{
        "user_id" => String.trim(user_id),
        "code_hash" => code_hash(code, nonce),
        "code_nonce" => nonce,
        "status" => "pending",
        "allowed_commands" => commands,
        "expires_at" => expires_at,
        "metadata" => opts |> Keyword.get(:metadata, %{}) |> stringify_keys()
      }

      %Pairing{}
      |> Pairing.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, pairing} ->
          record_change(user_id, "pairing_created", %{"mobile_node_pairing" => pairing.id}, %{
            allowed_commands: commands,
            expires_at: expires_at
          })

          {:ok, %{pairing: pairing, code: code, expires_at: expires_at}}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def create_pairing(_user_id, _opts), do: {:error, :invalid_mobile_pairing_attrs}

  def claim_pairing(user_id, code, attrs)
      when is_binary(user_id) and is_binary(code) and is_map(attrs) do
    now = DateTime.utc_now()

    case find_pending_pairing(user_id, code, now) do
      nil ->
        {:error, :pairing_not_found}

      %Pairing{} = pairing ->
        Repo.transaction(fn ->
          with {:ok, device} <-
                 register_device(
                   user_id,
                   Map.put(attrs, "allowed_commands", pairing.allowed_commands)
                 ),
               {:ok, claimed_pairing} <-
                 pairing
                 |> Pairing.changeset(%{
                   "status" => "claimed",
                   "claimed_at" => now,
                   "claimed_device_id" => device.device_id
                 })
                 |> Repo.update() do
            record_change(user_id, "pairing_claimed", %{
              "mobile_node_pairing" => claimed_pairing.id,
              "mobile_node_device" => device.id
            })

            %{pairing: claimed_pairing, device: device}
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
        |> case do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def claim_pairing(_user_id, _code, _attrs), do: {:error, :invalid_mobile_pairing_attrs}

  def register_device(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    attrs = stringify_keys(attrs)

    with {:ok, device_id} <- required_string(attrs, "device_id"),
         {:ok, commands} <- normalize_allowed_commands(Map.get(attrs, "allowed_commands")) do
      attrs =
        attrs
        |> Map.merge(%{
          "user_id" => String.trim(user_id),
          "device_id" => device_id,
          "status" => read_string(attrs, "status", "active"),
          "allowed_commands" => commands,
          "last_seen_at" => read_datetime(attrs, "last_seen_at") || DateTime.utc_now()
        })

      case Repo.get_by(Device, user_id: user_id, device_id: device_id) do
        nil -> %Device{} |> Device.changeset(attrs) |> Repo.insert()
        %Device{} = device -> device |> Device.changeset(attrs) |> Repo.update()
      end
      |> tap(fn
        {:ok, device} ->
          record_change(user_id, "device_registered", %{"mobile_node_device" => device.id}, %{
            device_id: device.device_id,
            allowed_commands: device.allowed_commands
          })

        _ ->
          :ok
      end)
    end
  end

  def register_device(_user_id, _attrs), do: {:error, :invalid_mobile_device_attrs}

  def authorize_command(device, command, payload \\ %{})

  def authorize_command(%Device{} = device, command, payload) when is_binary(command) do
    command = String.trim(command)

    cond do
      device.status != "active" ->
        {:error, :device_not_active}

      command in @forbidden_commands ->
        {:error, :forbidden_mobile_command}

      command not in @allowed_commands ->
        {:error, :unknown_mobile_command}

      command not in (device.allowed_commands || []) ->
        {:error, :mobile_command_not_granted}

      true ->
        {:ok, %{device_id: device.device_id, command: command, payload: payload || %{}}}
    end
  end

  def authorize_command(_device, _command, _payload),
    do: {:error, :invalid_mobile_command_context}

  def list_devices(user_id, opts \\ []) when is_binary(user_id) and is_list(opts) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()
    status = Keyword.get(opts, :status)

    Device
    |> where([device], device.user_id == ^user_id)
    |> maybe_filter(:status, status)
    |> order_by([device], desc: device.updated_at, desc: device.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_pairings(user_id, opts \\ []) when is_binary(user_id) and is_list(opts) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()
    status = Keyword.get(opts, :status)

    Pairing
    |> where([pairing], pairing.user_id == ^user_id)
    |> maybe_filter(:status, status)
    |> order_by([pairing], desc: pairing.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def redacted_device(%Device{} = device) do
    %{
      id: device.id,
      user_id: device.user_id,
      device_id: device.device_id,
      label: device.label,
      platform: device.platform,
      status: device.status,
      public_key_fingerprint: device.public_key_fingerprint,
      capability_keys: device.capabilities |> Map.keys() |> Enum.sort(),
      allowed_commands: device.allowed_commands || [],
      last_seen_at: device.last_seen_at,
      metadata: device.metadata || %{},
      inserted_at: device.inserted_at,
      updated_at: device.updated_at
    }
  end

  def redacted_pairing(%Pairing{} = pairing) do
    %{
      id: pairing.id,
      user_id: pairing.user_id,
      status: pairing.status,
      allowed_commands: pairing.allowed_commands || [],
      expires_at: pairing.expires_at,
      claimed_at: pairing.claimed_at,
      claimed_device_id: pairing.claimed_device_id,
      metadata: pairing.metadata || %{},
      inserted_at: pairing.inserted_at,
      updated_at: pairing.updated_at
    }
  end

  defp find_pending_pairing(user_id, code, now) do
    Pairing
    |> where([pairing], pairing.user_id == ^user_id)
    |> where([pairing], pairing.status == "pending" and pairing.expires_at > ^now)
    |> order_by([pairing], desc: pairing.inserted_at)
    |> Repo.all()
    |> Enum.find(&valid_code?(&1, code))
  end

  defp pairing_expiry(opts) do
    expires_at = Keyword.get(opts, :expires_at)
    ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_pairing_ttl_seconds)

    cond do
      match?(%DateTime{}, expires_at) ->
        {:ok, DateTime.truncate(expires_at, :second)}

      is_integer(ttl_seconds) and ttl_seconds > 0 and ttl_seconds <= 86_400 ->
        {:ok,
         DateTime.utc_now() |> DateTime.add(ttl_seconds, :second) |> DateTime.truncate(:second)}

      true ->
        {:error, :invalid_pairing_expiry}
    end
  end

  defp normalize_allowed_commands(nil), do: {:ok, @allowed_commands}

  defp normalize_allowed_commands(commands) when is_list(commands) do
    commands =
      commands
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    cond do
      commands == [] ->
        {:error, :empty_mobile_command_grants}

      Enum.any?(commands, &(&1 in @forbidden_commands)) ->
        {:error, :forbidden_mobile_command}

      Enum.any?(commands, &(&1 not in @allowed_commands)) ->
        {:error, :unknown_mobile_command}

      true ->
        {:ok, commands}
    end
  end

  defp normalize_allowed_commands(_commands), do: {:error, :invalid_mobile_command_grants}

  defp generate_pairing_code do
    :crypto.strong_rand_bytes(8)
    |> Base.encode32(case: :upper, padding: false)
    |> binary_part(0, 10)
    |> then(fn code -> String.slice(code, 0, 5) <> "-" <> String.slice(code, 5, 5) end)
  end

  defp valid_code?(%Pairing{} = pairing, code) do
    Plug.Crypto.secure_compare(code_hash(code, pairing.code_nonce), pairing.code_hash)
  rescue
    _error -> false
  end

  defp code_hash(code, nonce) when is_binary(code) and is_binary(nonce) do
    :crypto.hash(:sha256, nonce <> String.trim(code))
  end

  defp record_change(user_id, action, object_refs, metadata \\ %{}) do
    ActionLedger.record(%{
      user_id: user_id,
      surface: "mobile_node",
      event_type: "mobile_node.changed",
      status: "completed",
      result_object_refs: object_refs,
      metadata: Map.put(metadata, :action, action)
    })

    :ok
  rescue
    _error -> :ok
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query
  defp maybe_filter(query, field, value), do: where(query, [row], field(row, ^field) == ^value)

  defp required_string(attrs, key) do
    case read_string(attrs, key) do
      nil -> {:error, :"missing_#{key}"}
      value -> {:ok, value}
    end
  end

  defp read_string(attrs, key, default \\ nil) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    case Map.get(attrs, key, default) do
      nil -> default
      "" -> default
      value when is_binary(value) -> value |> String.trim() |> blank_to_default(default)
      value -> value |> to_string() |> String.trim() |> blank_to_default(default)
    end
  end

  defp read_datetime(attrs, key) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    case Map.get(attrs, key) do
      %DateTime{} = datetime ->
        datetime

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value

  defp clamp_limit(value) when is_integer(value), do: min(max(value, 1), @max_limit)
  defp clamp_limit(_value), do: @default_limit

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_value(value)}
      {key, value} when is_binary(key) -> {key, stringify_value(value)}
      {key, value} -> {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_keys(_value), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value
end
