defmodule Maraithon.HTTP.AdmissionTest do
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Maraithon.HTTP.Admission
  alias Maraithon.LLM.BoundedResponse
  alias Maraithon.Repo

  setup do
    key = "test:#{Ecto.UUID.generate()}"
    supervisor = start_supervised!(Task.Supervisor)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(
          "DELETE FROM background_job_rate_limits WHERE queue = 'http_gmail' AND rate_limit_key = $1",
          [key]
        )
      end)
    end)

    %{key: key, supervisor: supervisor}
  end

  test "separate database sessions serialize a mailbox while another mailbox proceeds", ctx do
    parent = self()

    holder =
      Task.Supervisor.async_nolink(ctx.supervisor, fn ->
        run(ctx.key, fn ->
          send(parent, :request_started)

          receive do
            :finish -> {:ok, :finished}
          end
        end)
      end)

    assert_receive :request_started

    # Expectation updated 2026-09-21: a busy lane used to be rejected on sight
    # as provider_busy, which surfaced as rate_limited and cost the Chief of
    # Staff its Slack workspace (and Gmail deltas) whenever two jobs read the
    # same source at the same moment. A waiter now polls until the lane frees,
    # bounded by half its request timeout, and is rejected only at the deadline.
    assert {:error, {:rate_limited, 1, :provider_busy}} =
             run(ctx.key, 300, fn -> flunk("overlapping mailbox request") end)

    waiter =
      Task.Supervisor.async_nolink(ctx.supervisor, fn ->
        run(ctx.key, fn -> {:ok, :waited} end)
      end)

    assert {:ok, :other_mailbox} = run(ctx.key <> ":other", fn -> {:ok, :other_mailbox} end)
    send(holder.pid, :finish)
    assert {:ok, :finished} = Task.await(holder)
    assert {:ok, :waited} = Task.await(waiter)
    assert {:ok, :next} = run(ctx.key, fn -> {:ok, :next} end)
  end

  test "cooldown survives its worker and is measured against database time", ctx do
    holder =
      Task.Supervisor.async_nolink(ctx.supervisor, fn ->
        run(ctx.key, fn -> {:error, {:rate_limited, 90, :provider_limited}} end)
      end)

    monitor = Process.monitor(holder.pid)
    assert {:error, {:rate_limited, 90, :provider_limited}} = Task.await(holder)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}

    assert {:error, {:rate_limited, seconds, :provider_cooldown}} =
             run(ctx.key, fn -> flunk("request sent during persisted cooldown") end)

    assert seconds in 89..90

    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!(
        "UPDATE background_job_rate_limits SET blocked_until = timezone('UTC', clock_timestamp()) - interval '1 second' WHERE queue = 'http_gmail' AND rate_limit_key = $1",
        [ctx.key]
      )
    end)

    assert {:ok, :resumed} = run(ctx.key, fn -> {:ok, :resumed} end)
  end

  test "missing Retry-After gets a durable bounded default", ctx do
    assert {:error, {:rate_limited, :provider_limited}} =
             run(ctx.key, fn -> {:error, {:rate_limited, :provider_limited}} end)

    assert {:error, {:rate_limited, seconds, :provider_cooldown}} =
             run(ctx.key, fn -> flunk("cooldown lost") end)

    assert seconds in 29..30
  end

  test "caller death stops its bounded request worker and releases admission", ctx do
    parent = self()

    {:ok, owner} =
      Task.Supervisor.start_child(ctx.supervisor, fn ->
        BoundedResponse.run(
          fn ->
            run(ctx.key, fn ->
              send(parent, {:inside_request, self()})

              receive do
                :should_never_finish -> flunk("orphan request continued")
              end
            end)
          end,
          10_000
        )
      end)

    assert_receive {:inside_request, worker}
    worker_monitor = Process.monitor(worker)
    owner_monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}

    # Wait for PostgreSQL to finish rollback after the connection owner dies.
    Sandbox.unboxed_run(Repo, fn ->
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '2s'")

        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))", [
          "http_gmail:#{ctx.key}"
        ])
      end)
    end)

    assert {:ok, :recovered} = run(ctx.key, fn -> {:ok, :recovered} end)
  end

  test "a busy second lane releases the first lane in the same transaction", ctx do
    parent = self()
    first = {"slack", ctx.key, 0}
    second = {"slack_channel", ctx.key, 0}

    holder =
      Task.Supervisor.async_nolink(ctx.supervisor, fn ->
        run([second], fn ->
          send(parent, :channel_held)

          receive do
            :finish -> {:ok, :finished}
          end
        end)
      end)

    assert_receive :channel_held

    # Bounded wait (see the first test): a short request timeout makes the
    # occupied channel lane reject at its deadline instead of waiting.
    assert {:error, {:rate_limited, 1, :provider_busy}} =
             run([first, second], 300, fn -> flunk("entered occupied channel") end)

    assert {:ok, :free} = run([first], fn -> {:ok, :free} end)
    send(holder.pid, :finish)
    assert {:ok, :finished} = Task.await(holder)
  end

  test "only a closed local rejection proves non-entry, including wrapped tool errors" do
    for kind <- [:provider_busy, :provider_cooldown], provider <- [:gmail, :slack] do
      reason = {:rate_limited, 30, kind}
      assert Admission.local_deferral(reason) == reason
      assert Admission.local_deferral({:provider_error, provider, reason, "safe copy"}) == reason
    end

    for reason <- [
          {:rate_limited, 30, :provider_limited},
          {:http_status, 429, "limited"},
          %{class: :ambiguous, reason: {:rate_limited, 30, :provider_busy}},
          {:provider_error, :calendar, {:rate_limited, 30, :provider_busy}, "copy"}
        ] do
      assert Admission.local_deferral(reason) == nil
    end
  end

  defp run(lanes, request) when is_list(lanes), do: run(lanes, 5_000, request)
  defp run(key, request), do: run(key, 5_000, request)

  defp run(lanes, timeout, request) when is_list(lanes) do
    Sandbox.unboxed_run(Repo, fn -> Admission.run(lanes, timeout, request) end)
  end

  defp run(key, timeout, request) do
    Sandbox.unboxed_run(Repo, fn -> Admission.run({"gmail", key}, timeout, request) end)
  end
end
