defmodule Maraithon.Runtime.DispatchTest do
  use ExUnit.Case, async: true

  alias Maraithon.Runtime.Dispatch

  test "receipts confirm enqueue without waiting for subscriber processing" do
    agent_id = Ecto.UUID.generate()
    parent = self()

    subscriber =
      start_supervised!(
        {Task,
         fn ->
           :ok = Dispatch.subscribe(agent_id)
           send(parent, {:subscribed, self()})

           receive do
             :release ->
               receive do
                 {:agent_dispatch, :work} -> send(parent, :processed)
               end
           end
         end}
      )

    assert_receive {:subscribed, ^subscriber}

    assert :ok = Dispatch.dispatch(agent_id, :work, receipt: {self(), :enqueued})
    assert_receive :enqueued
    refute_received :processed

    send(subscriber, :release)
    assert_receive :processed
  end

  test "does not emit a receipt without a subscriber" do
    assert :ok =
             Dispatch.dispatch(Ecto.UUID.generate(), :work,
               receipt: {self(), :unexpected_receipt}
             )

    refute_received :unexpected_receipt
  end
end
