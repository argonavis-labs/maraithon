defmodule Maraithon.Runtime.SourceAccountAdmissionTest do
  use Maraithon.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Maraithon.Repo
  alias Maraithon.Runtime.SourceAccountAdmission

  test "a reservation excludes a different database session and releases cleanly" do
    account_id = System.unique_integer([:positive])
    parent = self()

    holder =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          SourceAccountAdmission.with_reservations([account_id], fn ->
            send(parent, :source_account_reserved)

            receive do
              :release_source_account -> :released
            end
          end)
        end)
      end)

    assert_receive :source_account_reserved

    assert {:error, :source_account_reserved} =
             SourceAccountAdmission.try_transaction_lock(account_id)

    send(holder.pid, :release_source_account)
    assert :released = Task.await(holder)
    assert :ok = SourceAccountAdmission.try_transaction_lock(account_id)
  end
end
