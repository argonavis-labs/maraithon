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
  def spending_guard_usd, do: 7.0

  def development_spending?,
    do: Application.get_env(:maraithon, :llm_development_spending, false) == true

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

    samples = window_samples(samples, timestamp, usage.total)

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
      "rolling_coverage_seconds" => timestamp - first["at"],
      "rolling_window" =>
        if(timestamp - first["at"] >= @day_seconds, do: "upper_bound", else: "partial"),
      "projected_daily_usd" => projection,
      "threshold_usd" => 2 * projection
    })
    |> Map.delete("failure_code")
  end

  @doc false
  def window_samples(samples, timestamp, total) do
    cutoff = timestamp - @day_seconds
    history = Enum.filter(samples, &(&1["at"] <= timestamp)) |> Enum.sort_by(& &1["at"])
    {older, recent} = Enum.split_while(history, &(&1["at"] < cutoff))

    # Six-hour schedules drift. Dropping the sample just before the boundary
    # silently turns a 24-hour check into an 18-hour check. Keep that anchor and
    # label the interval honestly as a conservative upper bound.
    anchor = if Enum.any?(recent, &(&1["at"] == cutoff)), do: [], else: Enum.take(older, -1)

    anchor ++
      Enum.take(recent, -(@max_samples - length(anchor) - 1)) ++
      [%{"at" => timestamp, "total" => total}]
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

    spending_note =
      if development_spending?(),
        do:
          "Development spending is enabled. Work can continue above the spending guard while we build and test.",
        else:
          "The normal spending guard is US$#{money(spending_guard_usd())}. New model work for delegated conversations pauses above that amount until a later check is below it."

    text = """
    Maraithon's OpenRouter spend has passed twice the daily projection.

    Daily projection: US$#{money(state["projected_daily_usd"])}
    Warning threshold: US$#{money(state["threshold_usd"])}
    Billed today (#{state["utc_date"]}, UTC): US$#{money(state["daily_cost_usd"])}
    Observed rolling spend since #{since}: US$#{money(state["rolling_cost_usd"])}
    Checked at: #{state["checked_at"]}

    These amounts come from OpenRouter's billing counter for Maraithon's API key,
    including billed attempts that failed or were rejected by the app. Rolling
    checks use six-hour samples. Once history covers a day, the rolling amount
    includes the sample just before the 24-hour boundary, so it can cover slightly
    more than a day and warn conservatively. Before then it covers the available
    history. The exact interval starts at the time above. All models using this key count.

    Review model and request activity at https://openrouter.ai/activity.
    #{spending_note}
    Your saved tasks and conversations remain available.
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
