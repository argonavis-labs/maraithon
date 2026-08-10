defmodule Maraithon.DatabaseTLS do
  @moduledoc """
  Builds peer- and hostname-verifying PostgreSQL options for storage-only
  operator credentials.

  Production runtime configuration records the audited TLS mode in application
  config. Operator tasks that replace only the Repo URL must rebuild SSL
  options for that URL as well; reusing the runtime host's SNI would either
  fail closed or authenticate the wrong hostname.
  """

  @repo_transport_keys [:url, :ssl, :socket, :hostname]

  @doc "Replaces a Repo URL and its transport options without retaining stale SNI or sockets."
  def configure_repo!(url, env_name) when is_binary(url) and is_binary(env_name) do
    current = Application.get_env(:maraithon, Maraithon.Repo, [])
    replacement = repo_options!(url, env_name)

    updated =
      current
      |> Keyword.drop(@repo_transport_keys)
      |> Keyword.merge(replacement)

    Application.put_env(:maraithon, Maraithon.Repo, updated)
    :ok
  end

  @doc "Returns URL-scoped PostgreSQL TLS options under the audited production policy."
  def repo_options!(url, env_name) when is_binary(url) and is_binary(env_name) do
    case Application.get_env(:maraithon, :database_tls_audit) do
      nil ->
        [url: url]

      %{mode: :verify_peer} ->
        uri = verified_uri!(url, env_name)

        [
          url: url,
          ssl:
            [
              verify: :verify_peer,
              server_name_indication: String.to_charlist(uri.host),
              customize_hostname_check: [
                match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
              ]
            ] ++ ca_options!()
        ]

      %{mode: :insecure_override} ->
        _uri = verified_uri!(url, env_name, allow_unverified_query?: true)
        [url: url, ssl: false]

      _invalid ->
        raise "database TLS audit configuration is missing or invalid"
    end
  end

  def repo_options!(_url, _env_name), do: raise(ArgumentError, "invalid database URL")

  defp verified_uri!(url, env_name, opts \\ []) do
    uri = URI.parse(url)

    unless is_binary(uri.host) and uri.host != "" do
      raise "#{env_name} must contain a database hostname"
    end

    unless Keyword.get(opts, :allow_unverified_query?, false) do
      query = if uri.query, do: Enum.to_list(URI.query_decoder(uri.query)), else: []

      if Enum.any?(query, fn {key, value} ->
           case String.downcase(key) do
             "ssl" -> String.downcase(value) != "true"
             "sslmode" -> String.downcase(value) != "verify-full"
             _key -> false
           end
         end) do
        raise "#{env_name} contains a TLS query option that does not verify peer and hostname"
      end
    end

    uri
  end

  defp ca_options! do
    case System.get_env("DATABASE_TLS_CA_CERT_PATH", "") |> String.trim() do
      "" ->
        cacerts =
          try do
            :public_key.cacerts_get()
          rescue
            _error -> raise "could not load the operating-system CA trust store for database TLS"
          catch
            _kind, _reason ->
              raise "could not load the operating-system CA trust store for database TLS"
          end

        if cacerts == [] do
          raise "the operating-system CA trust store is empty; database TLS cannot be verified"
        end

        [cacerts: cacerts]

      path ->
        unless Path.type(path) == :absolute and File.regular?(path) do
          raise "DATABASE_TLS_CA_CERT_PATH must name an absolute readable CA certificate file"
        end

        [cacertfile: String.to_charlist(path)]
    end
  end
end
