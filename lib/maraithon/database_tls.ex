defmodule Maraithon.DatabaseTLS do
  @moduledoc """
  Builds peer- and hostname-verifying PostgreSQL options for storage-only
  operator credentials.

  Production runtime configuration records the audited TLS mode in application
  config. Operator tasks that replace only the Repo URL must rebuild SSL
  options for that URL as well; reusing the runtime host's SNI would either
  fail closed or authenticate the wrong hostname.
  """

  @repo_transport_keys [
    :url,
    :ssl,
    :socket,
    :hostname,
    :username,
    :password,
    :database,
    :socket_options
  ]
  @operator_roles %{
    "DURABLE_PAYLOAD_VERIFIER_DATABASE_URL" => "maraithon_payload_verifier",
    "MARAITHON_ACTIVATION_DATABASE_URL" => "maraithon_activation_operator",
    "MARAITHON_INCIDENT_DATABASE_URL" => "maraithon_incident_operator",
    "MARAITHON_MIGRATOR_DATABASE_URL" => "maraithon_migrator",
    "VAULT_ROTATION_DATABASE_URL" => "maraithon_incident_operator"
  }

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

  @doc "Installs a fixed, separately credentialed operator URL when configured."
  def configure_operator_repo_from_env!(env_name, production?)
      when is_map_key(@operator_roles, env_name) and is_boolean(production?) do
    url = System.get_env(env_name)
    present? = is_binary(url) and String.trim(url) != ""

    if production? and not present? do
      raise "#{env_name} is required in production"
    end

    if present? do
      expected_role = Map.fetch!(@operator_roles, env_name)

      unless Plug.Crypto.secure_compare(database_role!(url, env_name), expected_role) do
        raise "#{env_name} must use the canonical #{expected_role} database role"
      end

      if production? do
        require_distinct_credentials!(url, System.get_env("DATABASE_URL"), env_name)
      end

      configure_repo!(url, env_name)
    else
      :ok
    end
  end

  def configure_operator_repo_from_env!(env_name, _production?) do
    raise ArgumentError, "unsupported operator database URL environment: #{inspect(env_name)}"
  end

  @doc "Refuses an operator URL that reuses the runtime database role."
  def require_distinct_credentials!(operator_url, runtime_url, env_name)
      when is_binary(operator_url) and is_binary(runtime_url) and is_binary(env_name) do
    operator_role = database_role!(operator_url, env_name)
    runtime_role = database_role!(runtime_url, "DATABASE_URL")

    if Plug.Crypto.secure_compare(operator_role, runtime_role) do
      raise "#{env_name} must use a database role distinct from DATABASE_URL"
    end

    :ok
  end

  def require_distinct_credentials!(_operator_url, _runtime_url, env_name)
      when is_binary(env_name) do
    raise "#{env_name} and DATABASE_URL are required to prove distinct database roles"
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
        uri = verified_uri!(url, env_name, allow_unverified_query?: true)

        case System.get_env("CLOUD_SQL_SOCKET_DIR", "") |> String.trim() do
          "" -> [url: url, ssl: false]
          socket_dir -> cloud_sql_socket_options!(uri, env_name, socket_dir)
        end

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

  defp database_role!(url, env_name) do
    case URI.parse(url).userinfo do
      userinfo when is_binary(userinfo) and userinfo != "" ->
        userinfo
        |> String.split(":", parts: 2)
        |> hd()
        |> URI.decode()
        |> case do
          "" -> raise "#{env_name} must identify a database role"
          role -> role
        end

      _missing ->
        raise "#{env_name} must identify a database role"
    end
  rescue
    _error -> raise "#{env_name} must identify a valid database role"
  end

  defp cloud_sql_socket_options!(uri, env_name, socket_dir) do
    unless Path.type(socket_dir) == :absolute do
      raise "CLOUD_SQL_SOCKET_DIR must be an absolute path for #{env_name}"
    end

    {username, password} = database_credentials!(uri, env_name)
    database = uri.path |> to_string() |> String.trim_leading("/") |> URI.decode()

    if database == "" do
      raise "#{env_name} must identify a database"
    end

    [
      username: username,
      password: password,
      database: database,
      socket: Path.join(socket_dir, ".s.PGSQL.5432"),
      ssl: false
    ]
  end

  defp database_credentials!(uri, env_name) do
    case String.split(uri.userinfo || "", ":", parts: 2) do
      [username, password] when username != "" and password != "" ->
        {URI.decode(username), URI.decode(password)}

      _missing ->
        raise "#{env_name} must identify database credentials"
    end
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
