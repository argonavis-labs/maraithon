defmodule Maraithon.Tools.HttpGet.ResolverTest do
  use ExUnit.Case, async: true

  alias Maraithon.Tools.HttpGet.Resolver

  test "returns literal addresses without a DNS lookup, including legacy numeric IPv4 forms" do
    lookup = fn _hostname, _family, _timeout ->
      raise "literal addresses must not reach DNS"
    end

    assert {:ok, [{127, 0, 0, 1}]} =
             Resolver.resolve("127.1", 100, clock: fn -> 0 end, lookup: lookup)

    assert {:ok, [{0, 0, 0, 0, 0, 0, 0, 1}]} =
             Resolver.resolve("::1", 100, clock: fn -> 0 end, lookup: lookup)
  end

  test "resolves A and AAAA concurrently under the same absolute deadline" do
    test_pid = self()
    ipv4 = {93, 184, 216, 34}
    ipv6 = {0x2606, 0x2800, 0x0220, 1, 0x0248, 0x1893, 0x25C8, 0x1946}

    lookup = fn hostname, family, timeout ->
      send(test_pid, {:lookup, hostname, family, timeout})
      if family == :inet, do: {:ok, [ipv4]}, else: {:ok, [ipv6]}
    end

    assert {:ok, [^ipv4, ^ipv6]} =
             Resolver.resolve("example.com", 150, clock: fn -> 50 end, lookup: lookup)

    assert_received {:lookup, ~c"example.com", :inet, 100}
    assert_received {:lookup, ~c"example.com", :inet6, 100}
  end

  test "treats a family with no record as empty only after the other family completes" do
    ipv4 = {93, 184, 216, 34}

    lookup = fn _hostname, family, _timeout ->
      if family == :inet, do: {:ok, [ipv4]}, else: {:error, :nxdomain}
    end

    assert {:ok, [^ipv4]} =
             Resolver.resolve("example.com", 100, clock: fn -> 0 end, lookup: lookup)
  end

  test "fails closed when the absolute DNS deadline has already expired" do
    test_pid = self()

    lookup = fn _hostname, _family, _timeout ->
      send(test_pid, :lookup_called)
      {:ok, [{93, 184, 216, 34}]}
    end

    assert {:error, :dns_timeout} =
             Resolver.resolve("example.com", 10, clock: fn -> 10 end, lookup: lookup)

    refute_received :lookup_called
  end

  test "fails closed on a lookup error or malformed family response" do
    lookup_error = fn _hostname, family, _timeout ->
      if family == :inet, do: {:ok, [{93, 184, 216, 34}]}, else: {:error, :timeout}
    end

    assert {:error, {:dns_error, :inet6, :timeout}} =
             Resolver.resolve("example.com", 100, clock: fn -> 0 end, lookup: lookup_error)

    malformed = fn _hostname, family, _timeout ->
      if family == :inet, do: {:ok, [{0x2606, 0, 0, 0, 0, 0, 0, 1}]}, else: {:error, :nxdomain}
    end

    assert {:error, :invalid_dns_response} =
             Resolver.resolve("example.com", 100, clock: fn -> 0 end, lookup: malformed)
  end

  test "rejects an excessive DNS answer set" do
    addresses = for last <- 1..33, do: {93, 184, 216, last}

    lookup = fn _hostname, family, _timeout ->
      if family == :inet, do: {:ok, addresses}, else: {:error, :nodata}
    end

    assert {:error, :too_many_addresses} =
             Resolver.resolve("example.com", 100, clock: fn -> 0 end, lookup: lookup)
  end

  test "deduplicates answers only after both record families resolve" do
    ipv4 = {93, 184, 216, 34}

    lookup = fn _hostname, family, _timeout ->
      if family == :inet, do: {:ok, [ipv4, ipv4]}, else: {:error, :nodata}
    end

    assert {:ok, [^ipv4]} =
             Resolver.resolve("example.com", 100, clock: fn -> 0 end, lookup: lookup)
  end

  test "isolates crashing DNS lookups from the caller" do
    lookup = fn _hostname, family, _timeout ->
      if family == :inet, do: raise("lookup crashed"), else: {:error, :nodata}
    end

    assert {:error, {:dns_error, :inet, :lookup_failed}} =
             Resolver.resolve("example.com", 100, clock: fn -> 0 end, lookup: lookup)
  end
end
