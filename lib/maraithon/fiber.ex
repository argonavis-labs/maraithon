defmodule Maraithon.Fiber do
  @moduledoc "Bounded Fiber profile lookups. Only an existing email is sent to Fiber."

  def configured?, do: is_binary(api_key()) and api_key() != ""

  def reverse_email_lookup(email) when is_binary(email) do
    if configured?() do
      case Req.post("https://api.fiber.ai/v1/email-to-person/single/lite",
             json: %{apiKey: api_key(), email: email},
             receive_timeout: 15_000,
             connect_options: [timeout: 5_000],
             retry: false
           ) do
        {:ok, %{status: 200, body: %{} = body}} ->
          {:ok,
           %{
             profile: body |> get_in(["output", "data"]) |> List.wrap() |> List.first(),
             credits: get_in(body, ["chargeInfo", "creditsCharged"]) || 0
           }}

        {:ok, %{status: 404}} ->
          {:ok, %{profile: nil, credits: 0}}

        {:ok, %{status: status}} ->
          {:error, {:fiber_http_status, status}}

        {:error, _} ->
          {:error, :fiber_unavailable}
      end
    else
      {:error, :fiber_not_configured}
    end
  end

  defp api_key, do: Application.get_env(:maraithon, __MODULE__, []) |> Keyword.get(:api_key)
end
