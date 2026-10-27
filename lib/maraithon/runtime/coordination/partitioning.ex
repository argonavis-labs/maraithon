defmodule Maraithon.Runtime.Coordination.Partitioning do
  @moduledoc "Stable tenant-to-partition mapping shared with PostgreSQL."
  @count 64

  def count, do: @count
  def tenant_key(user_id) when is_binary(user_id) and user_id != "", do: "user:" <> user_id
  def tenant_key(_), do: nil

  def partition_for(tenant) when is_binary(tenant) and tenant != "" do
    <<value::unsigned-big-32, _::binary>> = :crypto.hash(:md5, tenant)
    rem(value, @count)
  end

  def partition_for(_), do: nil

  def rendezvous_owner(partition_id, node_ids)
      when is_integer(partition_id) and is_list(node_ids) do
    node_ids
    |> Enum.sort()
    |> Enum.max_by(
      fn node_id ->
        <<score::unsigned-big-64, _::binary>> =
          :crypto.hash(:sha256, "#{partition_id}:#{node_id}")

        score
      end,
      fn -> nil end
    )
  end
end
