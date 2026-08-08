defmodule Maraithon.LLM.BoundedResponseTest do
  use ExUnit.Case, async: true

  alias Maraithon.LLM.BoundedResponse

  test "collector rejects excessive response chunk fragmentation" do
    collector = BoundedResponse.collector(10_000)
    initial = {Req.new(), %Req.Response{status: 200, private: %{}}}

    {_request, response} =
      Enum.reduce_while(1..2_049, initial, fn _index, acc ->
        case collector.({:data, "x"}, acc) do
          {:cont, next} -> {:cont, next}
          {:halt, next} -> {:halt, next}
        end
      end)

    assert BoundedResponse.overflow?(response)
    assert BoundedResponse.body(response) == ""
  end

  test "kills timed-out work and leaves no tagged result in the caller mailbox" do
    assert {:error, %{reason: :timeout}} =
             BoundedResponse.run(
               fn ->
                 receive do
                   :finish -> {:ok, :late}
                 end
               end,
               5
             )

    {:messages, messages} = Process.info(self(), :messages)

    refute Enum.any?(messages, fn
             {ref, _result} when is_reference(ref) -> true
             _message -> false
           end)
  end

  test "request worker is cancelled when its owner dies" do
    parent = self()

    caller =
      spawn(fn ->
        BoundedResponse.run(
          fn ->
            send(parent, {:request_worker, self()})

            receive do
              :finish -> :ok
            end
          end,
          30_000
        )
      end)

    assert_receive {:request_worker, worker}
    worker_ref = Process.monitor(worker)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 1_000
  end
end
