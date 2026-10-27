defmodule Maraithon.Tools.HttpGet.AddressPolicyTest do
  use ExUnit.Case, async: true

  alias Maraithon.Tools.HttpGet.AddressPolicy

  test "allows ordinary public IPv4 and IPv6 unicast addresses" do
    assert AddressPolicy.global?({1, 1, 1, 1})
    assert AddressPolicy.global?({93, 184, 216, 34})
    assert AddressPolicy.global?({0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111})
    assert AddressPolicy.global?({0x2A00, 0x1450, 0x4009, 0x0821, 0, 0, 0, 0x200E})
  end

  test "rejects IPv4 special-use, local, multicast, and reserved ranges" do
    rejected = [
      {0, 0, 0, 1},
      {10, 255, 255, 255},
      {100, 64, 0, 0},
      {100, 127, 255, 255},
      {127, 255, 255, 255},
      {169, 254, 169, 254},
      {172, 16, 0, 0},
      {172, 31, 255, 255},
      {192, 0, 0, 9},
      {192, 0, 2, 1},
      {192, 88, 99, 1},
      {192, 168, 1, 1},
      {198, 18, 0, 1},
      {198, 51, 100, 1},
      {203, 0, 113, 1},
      {224, 0, 0, 1},
      {239, 255, 255, 255},
      {240, 0, 0, 1},
      {255, 255, 255, 255}
    ]

    assert Enum.all?(rejected, &(not AddressPolicy.global?(&1)))
  end

  test "rejects IPv6 local, transition, documentation, multicast, and reserved ranges" do
    rejected = [
      {0, 0, 0, 0, 0, 0, 0, 0},
      {0, 0, 0, 0, 0, 0, 0, 1},
      {0, 0, 0, 0, 0xFFFF, 0x7F00, 0, 1},
      {0x0064, 0xFF9B, 0, 0, 0, 0, 0, 1},
      {0x2001, 0, 0, 0, 0, 0, 0, 1},
      {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1},
      {0x2002, 0x0808, 0x0808, 0, 0, 0, 0, 1},
      {0x3FFF, 0, 0, 0, 0, 0, 0, 1},
      {0xFC00, 0, 0, 0, 0, 0, 0, 1},
      {0xFE80, 0, 0, 0, 0, 0, 0, 1},
      {0xFF02, 0, 0, 0, 0, 0, 0, 1}
    ]

    assert Enum.all?(rejected, &(not AddressPolicy.global?(&1)))
  end

  test "rejects malformed tuples" do
    refute AddressPolicy.global?({999, 1, 1, 1})
    refute AddressPolicy.global?({1, 2, 3})
    refute AddressPolicy.global?("1.1.1.1")
  end
end
