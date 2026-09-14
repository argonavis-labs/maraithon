defmodule Maraithon.LLM.CostMonitor do
  @moduledoc """
  Checks OpenRouter's billed key usage without making a model call.

  The recurring job's encrypted result holds a bounded sampling history and
  the last successful email time. The job runner persists both under its
  existing lease and outcome fence. Provider or email failures preserve that
  state and retry on the next cycle, including across deploys.
  """

  alias Maraithon.EmailDelivery
  alias Maraithon.LLM
  alias Maraithon.Runtime.BackgroundJob

  require Logger

  @day_seconds 86_400
  @interval_ms :timer.hours(6)
  @max_samples 6
  @recipient "kent.fenwick@gmail.com"

  def enabled?, do: config()[:enabled] == true
  def interval_ms, do: @interval_ms

  def run_once(%BackgroundJob{result: previous}) do
    state = previous || %{}

    with true <- enabled?(),
         {:ok, key} <- api_key(),
         {:ok, usage} <- fetch_usage(key) do
      now = DateTime.utc_now()
      state = observe(state, usage, key, now)
      {:ok, maybe_notify(state, now)}
    else
      false -> {:ok, Map.put(state, "status", "disabled")}
      {:error, reason} -> {:ok, failed(state, reason)}
    end
  end

  defp api_key do
    case LLM.openrouter_api_key() do
      key when is_binary(key) and byte_size(key) > 0 -> {:ok, key}
      _ -> {:error, :openrouter_key_missing}
    end
  end

  defp fetch_usage(key) do
    case Req.get("https://openrouter.ai/api/v1/key",
           auth: {:bearer, key},
           receive_timeout: 10_000,
           connect_options: [timeout: 5_000],
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"data" => %{"usage" => total, "usage_daily" => daily}}}}
      when is_number(total) and total >= 0 and is_number(daily) and daily >= 0 and
             daily <= total ->
        {:ok, %{total: total, daily: daily}}

      {:ok, %{status: 200}} ->
        {:error, :openrouter_usage_invalid}

      {:ok, %{status: _}} ->
        {:error, :openrouter_usage_rejected}

      {:error, _} ->
        {:error, :openrouter_usage_unavailable}
    end
  end

  defp observe(previous, usage, key, now) do
    timestamp = DateTime.to_unix(now)
    fingerprint = :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)

    samples =
      if previous["key_fingerprint"] == fingerprint,
        do: previous["samples"] || [],
        else: []

    # A key rotation or a provider counter reset starts a new history. The
    # provider's UTC-day counter still protects the first day of monitoring.
    samples =
      case List.last(samples) do
        %{"total" => total} when total > usage.total -> []
        _ -> samples
      end

    samples =
      (samples ++ [%{"at" => timestamp, "total" => usage.total}])
      |> Enum.filter(&(&1["at"] >= timestamp - @day_seconds and &1["at"] <= timestamp))
      |> Enum.take(-@max_samples)

    first = hd(samples)
    rolling = max(usage.total - first["total"], 0)
    projection = config() |> Keyword.fetch!(:projected_daily_usd)

    previous
    |> Map.merge(%{
      "status" => "observed",
      "key_fingerprint" => fingerprint,
      "samples" => samples,
      "checked_at" => DateTime.to_iso8601(now),
      "utc_date" => Date.to_iso8601(DateTime.to_date(now)),
      "daily_cost_usd" => usage.daily,
      "rolling_cost_usd" => rolling,
      "rolling_since" => first["at"],
      "projected_daily_usd" => projection,
      "threshold_usd" => 2 * projection
    })
    |> Map.delete("failure_code")
  end

  defp maybe_notify(state, now) do
    cost = max(state["daily_cost_usd"], state["rolling_cost_usd"])
    timestamp = DateTime.to_unix(now)

    Logger.info("OpenRouter cost monitor checked",
      provider: "openrouter",
      daily_cost_usd: state["daily_cost_usd"],
      rolling_cost_usd: state["rolling_cost_usd"],
      threshold_usd: state["threshold_usd"],
      cost_source: "provider_reported"
    )

    cond do
      cost <= state["threshold_usd"] ->
        Map.put(state, "status", "within_budget")

      is_integer(state["last_alert_at"]) and
          timestamp - state["last_alert_at"] < @day_seconds ->
        Map.put(state, "status", "alert_cooldown")

      true ->
        case EmailDelivery.send(@recipient, content(state)) do
          :ok ->
            Logger.warning("OpenRouter cost warning emailed",
              provider: "openrouter",
              daily_cost_usd: state["daily_cost_usd"],
              rolling_cost_usd: state["rolling_cost_usd"],
              threshold_usd: state["threshold_usd"]
            )

            state
            |> Map.put("status", "alert_sent")
            |> Map.put("last_alert_at", timestamp)

          :disabled ->
            failed(state, :cost_alert_email_not_configured)

          {:error, _} ->
            failed(state, :cost_alert_email_failed)
        end
    end
  end

  defp failed(state, reason) do
    Logger.error("OpenRouter cost monitoring needs attention",
      provider: "openrouter",
      failure_code: Atom.to_string(reason)
    )

    state
    |> Map.put("status", "error")
    |> Map.put("failure_code", Atom.to_string(reason))
    |> Map.put("last_failure_at", DateTime.utc_now() |> DateTime.to_iso8601())
  end

  defp content(state) do
    cost = max(state["daily_cost_usd"], state["rolling_cost_usd"])
    since = state["rolling_since"] |> DateTime.from_unix!() |> DateTime.to_iso8601()

    text = """
    Maraithon's OpenRouter spend has passed twice the daily projection.

    Daily projection: US$#{money(state["projected_daily_usd"])}
    Warning threshold: US$#{money(state["threshold_usd"])}
    Billed today (#{state["utc_date"]}, UTC): US$#{money(state["daily_cost_usd"])}
    Observed rolling spend since #{since}: US$#{money(state["rolling_cost_usd"])}
    Checked at: #{state["checked_at"]}

    These amounts come from OpenRouter's billing counter for Maraithon's API key,
    including billed attempts that failed or were rejected by the app. Rolling
    history covers up to 24 hours with six hours between checks; today's total also
    works immediately after monitoring starts. All models using this key count.

    Review model and request activity at https://openrouter.ai/activity.
    Maraithon continues running. This warning does not stop your assistant.
    If spend stays above the threshold, another warning can follow in 24 hours.
    """

    escaped = text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    %{
      subject:
        "Maraithon LLM cost warning: US$#{money(cost)} exceeds US$#{money(state["threshold_usd"])}",
      text_body: text,
      html_body:
        "<pre style=\"white-space:pre-wrap;font-family:system-ui,sans-serif\">#{escaped}</pre>"
    }
  end

  defp money(value), do: :erlang.float_to_binary(value / 1, decimals: 2)

  defp config do
    Application.get_env(:maraithon, __MODULE__,
      enabled: false,
      projected_daily_usd: 3.0
    )
  end
end
