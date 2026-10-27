defmodule Maraithon.Tools.HttpGet.AddressPolicy do
  @moduledoc false

  import Bitwise

  # IANA special-purpose ranges plus multicast and reserved space. Keeping this
  # list conservative is intentional: the HTTP tool only needs ordinary public
  # unicast destinations.
  @non_global_ipv4 [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 88, 99, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 4},
    {{240, 0, 0, 0}, 4}
  ]

  @global_unicast_ipv6 {{0x2000, 0, 0, 0, 0, 0, 0, 0}, 3}
  @non_global_ipv6 [
    {{0x2001, 0, 0, 0, 0, 0, 0, 0}, 23},
    {{0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0}, 32},
    {{0x2002, 0, 0, 0, 0, 0, 0, 0}, 16},
    {{0x3FFF, 0, 0, 0, 0, 0, 0, 0}, 20}
  ]

  @spec global?(:inet.ip_address()) :: boolean()
  def global?(address) when is_tuple(address) and tuple_size(address) == 4 do
    if valid_parts?(address, 0xFF) do
      address_integer = address_to_integer(address, 8)

      Enum.all?(@non_global_ipv4, fn {network, prefix_length} ->
        not in_cidr?(address_integer, address_to_integer(network, 8), prefix_length, 32)
      end)
    else
      false
    end
  end

  def global?(address) when is_tuple(address) and tuple_size(address) == 8 do
    if valid_parts?(address, 0xFFFF) do
      address_integer = address_to_integer(address, 16)
      {global_network, global_prefix_length} = @global_unicast_ipv6

      in_cidr?(
        address_integer,
        address_to_integer(global_network, 16),
        global_prefix_length,
        128
      ) and
        Enum.all?(@non_global_ipv6, fn {network, prefix_length} ->
          not in_cidr?(address_integer, address_to_integer(network, 16), prefix_length, 128)
        end)
    else
      false
    end
  end

  def global?(_address), do: false

  defp valid_parts?(address, maximum) do
    address
    |> Tuple.to_list()
    |> Enum.all?(&(is_integer(&1) and &1 >= 0 and &1 <= maximum))
  end

  defp address_to_integer(address, part_bits) do
    address
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, result -> result <<< part_bits ||| part end)
  end

  defp in_cidr?(address, network, prefix_length, address_bits) do
    mask = ((1 <<< prefix_length) - 1) <<< (address_bits - prefix_length)
    (address &&& mask) == (network &&& mask)
  end
end
