defmodule Maraithon.Spend do
  @moduledoc """
  Token usage and cost tracking for LLM calls.

  Pricing as of May 12, 2026 (per million tokens):
  - claude-3-5-sonnet: $3 input, $15 output
  - claude-3-opus: $15 input, $75 output
  - claude-3-haiku: $0.25 input, $1.25 output
  - claude-sonnet-4: $3 input, $15 output (default)
  - gpt-5.4: $2.50 input, $15 output
  - qwen/qwen3.7-max: $2.50 input, $7.50 output via OpenRouter

  GPT-5.4 has a 1.05M context window. OpenAI prices requests with more than
  272K input tokens at 2x input and 1.5x output for the full session.
  """

  import Ecto.Query
  alias Maraithon.Agents.Agent
  alias Maraithon.Repo
  alias Maraithon.Events.Event

  # Pricing per million tokens (in USD)
  @gpt_5_4_long_context_threshold 272_000
  @pricing %{
    # Claude 3.5 / Claude 4 models
    "claude-sonnet-4-20250514" => %{input: 3.0, output: 15.0},
    "claude-3-5-sonnet-20241022" => %{input: 3.0, output: 15.0},
    "claude-3-5-sonnet-20240620" => %{input: 3.0, output: 15.0},
    "claude-3-opus-20240229" => %{input: 15.0, output: 75.0},
    "claude-3-haiku-20240307" => %{input: 0.25, output: 1.25},
    # GPT-5.4 family
    "gpt-5.5" => %{input: 5.0, output: 30.0},
    "gpt-5.4" => %{
      input: 2.5,
      output: 15.0,
      long_context_threshold: @gpt_5_4_long_context_threshold,
      long_context_input_multiplier: 2.0,
      long_context_output_multiplier: 1.5
    },
    "gpt-5.4-2026-03-05" => %{
      input: 2.5,
      output: 15.0,
      long_context_threshold: @gpt_5_4_long_context_threshold,
      long_context_input_multiplier: 2.0,
      long_context_output_multiplier: 1.5
    },
    "gpt-5.4-pro" => %{
      input: 30.0,
      output: 180.0,
      long_context_threshold: @gpt_5_4_long_context_threshold,
      long_context_input_multiplier: 2.0,
      long_context_output_multiplier: 1.5
    },
    "gpt-5.4-mini" => %{input: 0.75, output: 4.5},
    "gpt-5.4-nano" => %{input: 0.2, output: 1.25},
    # OpenRouter models
    "qwen/qwen3.7-max" => %{input: 2.50, output: 7.50},
    # Fallback for unknown models
    "default" => %{input: 3.0, output: 15.0}
  }

  @web_search_per_1k_calls 10.0

  @doc """
  Calculate the cost of an LLM call in USD.
  """
  def calculate_cost(model, input_tokens, output_tokens) do
    pricing = Map.get(@pricing, model, @pricing["default"])
    {input_multiplier, output_multiplier} = context_multipliers(pricing, input_tokens)

    input_cost = input_tokens / 1_000_000 * pricing.input * input_multiplier
    output_cost = output_tokens / 1_000_000 * pricing.output * output_multiplier

    %{
      input_cost: Float.round(input_cost, 6),
      output_cost: Float.round(output_cost, 6),
      total_cost: Float.round(input_cost + output_cost, 6),
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: input_tokens + output_tokens,
      input_rate_per_million: pricing.input,
      output_rate_per_million: pricing.output,
      input_multiplier: input_multiplier,
      output_multiplier: output_multiplier,
      model: model
    }
  end

  def web_search_cost(call_count) when is_integer(call_count) and call_count >= 0 do
    total_cost = call_count / 1_000 * @web_search_per_1k_calls

    %{
      call_count: call_count,
      rate_per_1k_calls: @web_search_per_1k_calls,
      total_cost: Float.round(total_cost, 6)
    }
  end

  def web_search_cost(_call_count), do: web_search_cost(0)

  defp context_multipliers(%{long_context_threshold: threshold} = pricing, input_tokens)
       when is_integer(input_tokens) and input_tokens > threshold do
    {
      Map.get(pricing, :long_context_input_multiplier, 1.0),
      Map.get(pricing, :long_context_output_multiplier, 1.0)
    }
  end

  defp context_multipliers(_pricing, _input_tokens), do: {1.0, 1.0}

  @doc """
  Get total spend for an agent from their events.
  """
  def get_agent_spend(agent_id) do
    Event
    |> where([event], event.agent_id == ^agent_id)
    |> where([event], event.event_type == "effect_completed")
    |> aggregate_spend()
  end

  @doc """
  Get total spend across all agents.
  """
  def get_total_spend(opts \\ []) do
    Event
    |> where([event], event.event_type == "effect_completed")
    |> maybe_filter_spend_user(Keyword.get(opts, :user_id))
    |> aggregate_spend()
  end

  # Aggregate inside Postgres instead of loading every historical effect payload
  # into the BEAM. The admin dashboard calls this on every refresh, and the old
  # approach transferred tens of thousands of JSON documents just to sum four
  # numeric fields.
  defp aggregate_spend(query) do
    query
    |> select([event], %{
      total_cost:
        fragment(
          """
          COALESCE(
            SUM(
              CASE
                WHEN jsonb_typeof(? #> '{result,usage,total_cost}') = 'number'
                  THEN (? #>> '{result,usage,total_cost}')::double precision
                ELSE 0
              END
            ),
            0
          )::double precision
          """,
          event.payload,
          event.payload
        ),
      input_tokens:
        fragment(
          """
          COALESCE(
            SUM(
              CASE
                WHEN jsonb_typeof(? #> '{result,usage,input_tokens}') = 'number'
                  THEN (? #>> '{result,usage,input_tokens}')::bigint
                ELSE 0
              END
            ),
            0
          )::bigint
          """,
          event.payload,
          event.payload
        ),
      output_tokens:
        fragment(
          """
          COALESCE(
            SUM(
              CASE
                WHEN jsonb_typeof(? #> '{result,usage,output_tokens}') = 'number'
                  THEN (? #>> '{result,usage,output_tokens}')::bigint
                ELSE 0
              END
            ),
            0
          )::bigint
          """,
          event.payload,
          event.payload
        ),
      llm_calls:
        fragment(
          "COUNT(*) FILTER (WHERE jsonb_typeof(? #> '{result,usage}') = 'object')::bigint",
          event.payload
        )
    })
    |> Repo.one!()
  end

  defp maybe_filter_spend_user(query, nil), do: query
  defp maybe_filter_spend_user(query, ""), do: query

  defp maybe_filter_spend_user(query, user_id) when is_binary(user_id) do
    agent_ids = from(agent in Agent, where: agent.user_id == ^user_id, select: agent.id)
    where(query, [event], event.agent_id in subquery(agent_ids))
  end
end
