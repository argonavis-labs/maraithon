defmodule Maraithon.DatabaseTLSTest do
  use ExUnit.Case, async: false

  alias Maraithon.DatabaseTLS

  setup do
    audit = Application.get_env(:maraithon, :database_tls_audit)
    repo = Application.get_env(:maraithon, Maraithon.Repo)
    ca_path = System.get_env("DATABASE_TLS_CA_CERT_PATH")
    runtime_url = System.get_env("DATABASE_URL")
    activation_url = System.get_env("MARAITHON_ACTIVATION_DATABASE_URL")
    cloud_sql_socket_dir = System.get_env("CLOUD_SQL_SOCKET_DIR")
    System.delete_env("DATABASE_TLS_CA_CERT_PATH")
    System.delete_env("CLOUD_SQL_SOCKET_DIR")

    on_exit(fn ->
      restore_env(:database_tls_audit, audit)
      restore_env(Maraithon.Repo, repo)
      restore_system_env("DATABASE_TLS_CA_CERT_PATH", ca_path)
      restore_system_env("DATABASE_URL", runtime_url)
      restore_system_env("MARAITHON_ACTIVATION_DATABASE_URL", activation_url)
      restore_system_env("CLOUD_SQL_SOCKET_DIR", cloud_sql_socket_dir)
    end)

    :ok
  end

  test "operator URLs rebuild peer verification for their own hostname" do
    Application.put_env(:maraithon, :database_tls_audit, %{
      mode: :verify_peer,
      ca_source: :operating_system
    })

    options =
      DatabaseTLS.repo_options!(
        "ecto://operator:secret@operator-db.example/app",
        "OPERATOR_DATABASE_URL"
      )

    ssl = Keyword.fetch!(options, :ssl)
    assert Keyword.fetch!(ssl, :verify) == :verify_peer
    assert Keyword.fetch!(ssl, :server_name_indication) == ~c"operator-db.example"
    assert Keyword.has_key?(ssl, :customize_hostname_check)
    assert Keyword.has_key?(ssl, :cacerts)
  end

  test "operator URLs reject query parameters that weaken TLS" do
    Application.put_env(:maraithon, :database_tls_audit, %{mode: :verify_peer})

    assert_raise RuntimeError, ~r/does not verify peer and hostname/, fn ->
      DatabaseTLS.repo_options!(
        "ecto://operator:secret@operator-db.example/app?sslmode=require",
        "OPERATOR_DATABASE_URL"
      )
    end
  end

  test "operator credentials must use a distinct database role" do
    assert :ok =
             DatabaseTLS.require_distinct_credentials!(
               "ecto://maraithon_incident_operator:operator-secret@db.example/app",
               "ecto://maraithon_runtime:runtime-secret@db.example/app",
               "MARAITHON_INCIDENT_DATABASE_URL"
             )

    assert_raise RuntimeError, ~r/database role distinct/, fn ->
      DatabaseTLS.require_distinct_credentials!(
        "ecto://maraithon_runtime:other-secret@other-db.example/app",
        "ecto://maraithon_runtime:runtime-secret@db.example/app",
        "MARAITHON_INCIDENT_DATABASE_URL"
      )
    end
  end

  test "credential comparison normalizes escaped role names" do
    assert_raise RuntimeError, ~r/database role distinct/, fn ->
      DatabaseTLS.require_distinct_credentials!(
        "ecto://maraithon%5Fruntime:operator-secret@other-db.example/app",
        "ecto://maraithon_runtime:runtime-secret@db.example/app",
        "MARAITHON_ACTIVATION_DATABASE_URL"
      )
    end
  end

  test "production operator configuration requires its canonical role URL" do
    System.put_env("DATABASE_URL", "ecto://maraithon_runtime:runtime-secret@db.example/app")
    System.delete_env("MARAITHON_ACTIVATION_DATABASE_URL")

    assert_raise RuntimeError, ~r/required in production/, fn ->
      DatabaseTLS.configure_operator_repo_from_env!(
        "MARAITHON_ACTIVATION_DATABASE_URL",
        true
      )
    end

    System.put_env(
      "MARAITHON_ACTIVATION_DATABASE_URL",
      "ecto://maraithon_runtime:other-secret@db.example/app"
    )

    assert_raise RuntimeError, ~r/canonical maraithon_activation_operator/, fn ->
      DatabaseTLS.configure_operator_repo_from_env!(
        "MARAITHON_ACTIVATION_DATABASE_URL",
        true
      )
    end

    System.put_env(
      "MARAITHON_ACTIVATION_DATABASE_URL",
      "ecto://maraithon_activation_operator:operator-secret@db.example/app"
    )

    assert :ok =
             DatabaseTLS.configure_operator_repo_from_env!(
               "MARAITHON_ACTIVATION_DATABASE_URL",
               true
             )
  end

  test "operator configuration rejects unreviewed environment names" do
    assert_raise ArgumentError, ~r/unsupported operator database URL/, fn ->
      DatabaseTLS.configure_operator_repo_from_env!("ARBITRARY_DATABASE_URL", false)
    end
  end

  test "configuring an operator URL drops stale runtime transport options" do
    Application.put_env(:maraithon, :database_tls_audit, %{mode: :insecure_override})

    Application.put_env(:maraithon, Maraithon.Repo,
      url: "ecto://runtime@runtime-db.example/app",
      socket: "/tmp/postgres.sock",
      ssl: [server_name_indication: ~c"runtime-db.example"],
      pool_size: 2
    )

    assert :ok =
             DatabaseTLS.configure_repo!(
               "ecto://operator@operator-db.example/app",
               "OPERATOR_DATABASE_URL"
             )

    configured = Application.fetch_env!(:maraithon, Maraithon.Repo)
    assert configured[:url] == "ecto://operator@operator-db.example/app"
    assert configured[:ssl] == false
    assert configured[:pool_size] == 2
    refute Keyword.has_key?(configured, :socket)
  end

  test "operator configuration rebuilds Cloud SQL socket credentials from its own URL" do
    Application.put_env(:maraithon, :database_tls_audit, %{mode: :insecure_override})
    System.put_env("CLOUD_SQL_SOCKET_DIR", "/cloudsql/project:region:instance")

    Application.put_env(:maraithon, Maraithon.Repo,
      username: "maraithon_runtime",
      password: "runtime-secret",
      database: "maraithon",
      socket: "/cloudsql/project:region:instance/.s.PGSQL.5432",
      pool_size: 2
    )

    assert :ok =
             DatabaseTLS.configure_repo!(
               "ecto://maraithon_incident_operator:incident%3Asecret@localhost/maraithon",
               "MARAITHON_INCIDENT_DATABASE_URL"
             )

    configured = Application.fetch_env!(:maraithon, Maraithon.Repo)
    assert configured[:username] == "maraithon_incident_operator"
    assert configured[:password] == "incident:secret"
    assert configured[:database] == "maraithon"
    assert configured[:socket] == "/cloudsql/project:region:instance/.s.PGSQL.5432"
    assert configured[:ssl] == false
    assert configured[:pool_size] == 2
    refute Keyword.has_key?(configured, :url)
  end

  defp restore_env(key, nil), do: Application.delete_env(:maraithon, key)
  defp restore_env(key, value), do: Application.put_env(:maraithon, key, value)

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)
end
