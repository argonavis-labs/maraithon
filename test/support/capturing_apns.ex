defmodule Maraithon.TestSupport.CapturingAPNS do
  @moduledoc false
  # APNs HTTP double: records every push into the :capturing_apns_recorder
  # Agent (start it in the test setup) and messages the caller. Pair with
  # `enable/1` which configures a signing key and registers a device so
  # `Push.Notifier.enabled_for_user?/1` is true for the test user.

  def post(url, _headers, body) do
    payload = Jason.decode!(body)
    event = %{url: url, payload: payload}

    if Process.whereis(:capturing_apns_recorder) do
      Agent.update(:capturing_apns_recorder, &[event | &1])
    end

    send(self(), {:apns_push, payload})
    {:ok, 200, ""}
  end

  @doc """
  Configures APNs with a throwaway key + this double, and registers an
  active device for `user_id`. Restores prior config via `ExUnit` on_exit —
  call from a setup block or test body.
  """
  def enable(user_id) do
    if Process.whereis(:capturing_apns_recorder) == nil do
      {:ok, pid} = Agent.start_link(fn -> [] end, name: :capturing_apns_recorder)
      ExUnit.Callbacks.on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
    end

    previous = Application.get_env(:maraithon, :apns, [])

    ec_key = :public_key.generate_key({:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, ec_key)])

    Application.put_env(:maraithon, :apns,
      team_id: "TEAM123456",
      key_id: "KEY1234567",
      private_key: pem,
      http_module: __MODULE__
    )

    Maraithon.Push.APNS.reset_jwt_cache()

    ExUnit.Callbacks.on_exit(fn ->
      Maraithon.Push.APNS.reset_jwt_cache()
      Application.put_env(:maraithon, :apns, previous)
    end)

    {:ok, _device} =
      Maraithon.Push.Devices.register(user_id, %{
        device_token: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
      })

    :ok
  end

  def recorded do
    case Process.whereis(:capturing_apns_recorder) do
      nil -> []
      _pid -> Agent.get(:capturing_apns_recorder, &Enum.reverse/1)
    end
  end
end
