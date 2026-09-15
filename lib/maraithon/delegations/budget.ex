defmodule Maraithon.Delegations.Budget do
  @moduledoc "Conservative model reservations survive retries, grant changes, and lost responses."
  import Ecto.Query
  alias Maraithon.{HTTP, LLM, Repo}
  alias Maraithon.Delegations.{Authority, Binding, Delegation, Preferences, Turn}
  alias Maraithon.Runtime.{BackgroundJob, DatabaseClock, JobAuthority, RecurringJobs}

  @output_tokens 2_048

  def quote(model) do
    if is_binary(model) and Regex.match?(~r/^[A-Za-z0-9._-]+\/[A-Za-z0-9._:-]+$/, model) do
      with {:ok, %{"data" => %{"id" => ^model, "endpoints" => endpoints}}} <-
             HTTP.get("https://openrouter.ai/api/v1/models/#{model}/endpoints", [],
               max_response_body_bytes: 128_000
             ),
           {:ok, quote} <- price(endpoints) do
        {:ok,
         Map.merge(quote, %{
           "model" => model,
           "quoted_at" => DateTime.to_iso8601(DateTime.utc_now())
         })}
      else
        _ -> {:error, :model_price_unavailable}
      end
    else
      {:error, :model_price_unavailable}
    end
  end

  @doc false
  def price(endpoints) when is_list(endpoints) and endpoints != [] do
    # Reserve a whole context at the maximum price, not an optimistic tokenizer
    # estimate. Text-only calls expose no paid web-search or other native tools.
    prices = Enum.map(endpoints, &endpoint_price/1)

    if Enum.all?(prices, &is_map/1) do
      rates =
        Map.new(~w(prompt completion request), fn key ->
          {key, Enum.map(prices, & &1[key]) |> Enum.reduce(&Decimal.max/2)}
        end)

      prompt_tokens = Enum.max(Enum.map(prices, & &1["context_length"]))

      micro =
        rates["prompt"]
        |> Decimal.mult(prompt_tokens)
        |> Decimal.add(Decimal.mult(rates["completion"], @output_tokens))
        |> Decimal.add(rates["request"])
        |> micro_usd()

      {:ok,
       %{
         "reserved_micro_usd" => micro,
         "max_tokens" => @output_tokens,
         "prompt_token_bound" => prompt_tokens,
         "provider" => %{
           "require_parameters" => true,
           "allow_fallbacks" => false,
           "only" => Enum.map(prices, & &1["tag"]),
           "max_price" => %{
             "prompt" => rates["prompt"] |> Decimal.mult(1_000_000) |> Decimal.to_string(:normal),
             "completion" =>
               rates["completion"] |> Decimal.mult(1_000_000) |> Decimal.to_string(:normal),
             "request" => Decimal.to_string(rates["request"], :normal)
           }
         }
       }}
    else
      {:error, :model_price_unavailable}
    end
  end

  def price(_), do: {:error, :model_price_unavailable}

  # Called in the same transaction as the continuation's model_entered phase.
  # The user privacy lock serializes decisions across all their delegations.
  def reserve!(context, key, quote) when key in ~w(compose policy) do
    unless Repo.in_transaction?(), do: raise(ArgumentError, "model reservation needs authority")
    turn = context.turn
    entries = turn.data["model_entries"] || %{}
    limits = Map.merge(Preferences.defaults(), context.grant.data["scope"]["limits"] || %{})
    amount = quote["reserved_micro_usd"]
    now = DatabaseClock.now!()

    cond do
      not is_integer(amount) or amount < 0 ->
        {:error, :model_price_unavailable}

      not Authority.current?(context, context.run.prompt_snapshot[Binding.key()]) ->
        {:error, :delegation_superseded}

      Map.has_key?(entries, key) ->
        {:error, :model_already_entered}

      quote["model"] != turn.model ->
        {:error, :model_changed}

      turn.model_calls >= limits["model_calls_per_turn"] ->
        {:error, :model_call_limit}

      not fresh_quote?(quote, now) ->
        {:error, :model_price_expired}

      not account_budget_ok?(now) ->
        {:error, :account_cost_hold}

      window_cost(turn.user_id, turn.delegation_id, DateTime.add(now, -30, :day)) + amount >
          limits["micro_usd_per_30d"] ->
        {:error, :delegation_cost_limit}

      window_cost(turn.user_id, nil, DateTime.add(now, -1, :day)) + amount >
          limits["user_micro_usd_per_day"] ->
        {:error, :user_cost_limit}

      true ->
        entry =
          Map.merge(quote, %{"state" => "entered", "entered_at" => DateTime.to_iso8601(now)})

        turn
        |> Turn.changeset(%{
          model_calls: turn.model_calls + 1,
          reserved_micro_usd: turn.reserved_micro_usd + amount,
          data: Map.put(turn.data, "model_entries", Map.put(entries, key, entry))
        })
        |> Repo.update!()

        :ok
    end
  end

  # Billing evidence still belongs to an old turn if a reply or stop arrived
  # while the provider worked. Settlement never grants permission to dispatch.
  def settle(
        %BackgroundJob{job_type: "delegation_decide"} = job,
        key,
        response,
        fun \\ fn _ -> :ok end
      ) do
    JobAuthority.transaction(job, fn ->
      context = Authority.lock_context!(job.payload, job.user_id)

      unless Authority.matches_job?(job, context.run.prompt_snapshot[Binding.key()]),
        do: Repo.rollback(:delegation_job_mismatch)

      turn = context.turn
      entries = turn.data["model_entries"] || %{}
      entry = entries[key]
      cost = get_in(response, [:usage, :reported_cost])

      if is_map(entry) and entry["state"] == "entered" and is_number(cost) and cost >= 0 and
           cost < 1_000_000 do
        micro = cost |> number() |> micro_usd()

        entry =
          Map.merge(entry, %{
            "state" => "settled",
            "cost_micro_usd" => micro,
            "actual_model" => response[:model],
            "input_tokens" => response[:tokens_in],
            "output_tokens" => response[:tokens_out]
          })

        turn
        |> Turn.changeset(%{
          reserved_micro_usd: turn.reserved_micro_usd - entry["reserved_micro_usd"],
          cost_micro_usd: turn.cost_micro_usd + micro,
          data: Map.put(turn.data, "model_entries", Map.put(entries, key, entry))
        })
        |> Repo.update!()

        d = context.delegation

        d
        |> Delegation.changeset(%{lifetime_micro_usd: d.lifetime_micro_usd + micro})
        |> Repo.update!()
      else
        # Missing billable receipts leave the reservation outstanding. Neither
        # a retry nor the passage of a budget window refunds unknown spend.
        :reservation_retained
      end

      fun.(context)
    end)
  end

  defp window_cost(user_id, delegation_id, cutoff) do
    query =
      from t in Turn,
        where: t.user_id == ^user_id and (t.updated_at >= ^cutoff or t.reserved_micro_usd > 0)

    query =
      if delegation_id, do: where(query, [t], t.delegation_id == ^delegation_id), else: query

    case Repo.one(from t in query, select: sum(t.cost_micro_usd + t.reserved_micro_usd)) do
      %Decimal{} = value -> Decimal.to_integer(value)
      nil -> 0
      value when is_integer(value) -> value
    end
  end

  defp account_budget_ok?(now) do
    type = RecurringJobs.job_type("llm_cost_monitor")

    job =
      Repo.one(
        from j in BackgroundJob,
          where: j.job_type == ^type,
          order_by: [desc: j.updated_at],
          limit: 1
      )
      |> BackgroundJob.hydrate_payloads()

    state = if job, do: job.result || %{}, else: %{}

    with true <- Maraithon.LLM.CostMonitor.enabled?(),
         {:ok, checked, _} <- DateTime.from_iso8601(state["checked_at"] || ""),
         age when age >= 0 and age <= 25_200 <- DateTime.diff(now, checked),
         daily when is_number(daily) <- state["daily_cost_usd"],
         rolling when is_number(rolling) <- state["rolling_cost_usd"],
         threshold when is_number(threshold) <- state["threshold_usd"],
         true <- state["status"] in ~w(within_budget observed),
         true <-
           state["key_fingerprint"] ==
             :crypto.hash(:sha256, LLM.openrouter_api_key() || "") |> Base.encode16(case: :lower) do
      max(daily, rolling) <= threshold
    else
      _ -> false
    end
  end

  defp fresh_quote?(quote, now) do
    with {:ok, at, _} <- DateTime.from_iso8601(quote["quoted_at"] || ""),
         seconds when seconds in 0..60 <- DateTime.diff(now, at),
         do: true,
         else: (_ -> false)
  end

  defp endpoint_price(endpoint) when is_map(endpoint) do
    pricing = endpoint["pricing"] || %{}

    rates =
      Map.new(
        ~w(prompt completion request),
        &{&1, number(pricing[&1] || if(&1 == "request", do: "0"))}
      )

    if is_integer(endpoint["context_length"]) and endpoint["context_length"] in 1..2_000_000 and
         is_binary(endpoint["tag"]) and is_list(endpoint["supported_parameters"]) and
         "max_tokens" in endpoint["supported_parameters"] and
         Enum.all?(rates, fn {_, n} ->
           is_struct(n, Decimal) and Decimal.compare(n, 0) != :lt and
             Decimal.compare(n, 10) != :gt
         end) do
      Map.merge(rates, Map.take(endpoint, ~w(context_length tag)))
    end
  end

  defp endpoint_price(_), do: nil
  defp number(value) when is_integer(value), do: Decimal.new(value)
  defp number(value) when is_float(value), do: Decimal.from_float(value)

  defp number(value) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{coef: coef} = n, ""} when is_integer(coef) -> n
      _ -> nil
    end
  end

  defp number(_), do: nil

  defp micro_usd(value),
    do: value |> Decimal.mult(1_000_000) |> Decimal.round(0, :ceiling) |> Decimal.to_integer()
end
