defmodule Maraithon.Telemetry.OtelSamplerTest do
  use ExUnit.Case, async: true

  alias Maraithon.Telemetry.OtelSampler

  describe "ecto_query_span?/1" do
    test "matches opentelemetry_ecto query span names" do
      assert OtelSampler.ecto_query_span?("maraithon.repo.query:scheduled_jobs")
      assert OtelSampler.ecto_query_span?("maraithon.repo.query:effects")
    end

    test "does not match application or HTTP span names" do
      refute OtelSampler.ecto_query_span?("telegram_assistant.run_inbound")
      refute OtelSampler.ecto_query_span?("chief_of_staff.morning_briefing")
      refute OtelSampler.ecto_query_span?("GET /webhooks/telegram")
      refute OtelSampler.ecto_query_span?(nil)
    end
  end

  describe "should_sample/7" do
    test "drops root Ecto query spans" do
      ctx = :otel_ctx.new()

      assert {:drop, [], _tracestate} =
               OtelSampler.should_sample(
                 ctx,
                 :otel_id_generator.generate_trace_id(),
                 [],
                 "maraithon.repo.query:scheduled_jobs",
                 :internal,
                 %{},
                 []
               )
    end

    test "keeps non-Ecto root spans" do
      ctx = :otel_ctx.new()

      assert {:record_and_sample, [], _tracestate} =
               OtelSampler.should_sample(
                 ctx,
                 :otel_id_generator.generate_trace_id(),
                 [],
                 "telegram_assistant.run_inbound",
                 :internal,
                 %{},
                 []
               )
    end
  end
end
