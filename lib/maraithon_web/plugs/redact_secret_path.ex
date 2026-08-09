defmodule MaraithonWeb.Plugs.RedactSecretPath do
  @moduledoc false

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(
        %Plug.Conn{path_info: ["webhooks", "telegram", _secret | _suffix]} = conn,
        _opts
      ) do
    %{conn | request_path: "/webhooks/telegram/[REDACTED]"}
  end

  def call(conn, _opts), do: conn
end
