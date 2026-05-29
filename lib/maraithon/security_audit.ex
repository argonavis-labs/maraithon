defmodule Maraithon.SecurityAudit do
  @moduledoc """
  Production-readiness checks for the trust layer and high-risk runtime knobs.
  """

  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Redaction
  alias Maraithon.Repo
  alias Maraithon.Tools

  @webhook_configs [
    {:github, :webhook_secret},
    {:slack, :signing_secret},
    {:whatsapp, :app_secret},
    {:linear, :webhook_secret},
    {:telegram, :webhook_secret_path}
  ]

  def run(opts \\ []) when is_list(opts) do
    env = opts |> Keyword.get(:env, current_env()) |> normalize_env()

    findings =
      []
      |> add_webhook_findings(env)
      |> add_api_auth_findings(env)
      |> add_admin_auth_findings(env)
      |> add_tool_policy_findings()
      |> add_file_root_findings(env)
      |> add_connected_account_findings()
      |> add_redaction_findings()
      |> Enum.reverse()

    %{
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      environment: Atom.to_string(env),
      status: audit_status(findings),
      summary: %{
        critical: count_severity(findings, "critical"),
        high: count_severity(findings, "high"),
        medium: count_severity(findings, "medium"),
        low: count_severity(findings, "low")
      },
      findings: findings
    }
  end

  defp add_webhook_findings(findings, env) do
    Enum.reduce(@webhook_configs, findings, fn {app_key, secret_key}, acc ->
      config = Application.get_env(:maraithon, app_key, [])
      allow_unsigned? = Keyword.get(config, :allow_unsigned, false) == true
      secret = config |> Keyword.get(secret_key, "") |> blank?()

      acc
      |> maybe_add(
        allow_unsigned?,
        %{
          id: "webhook_unsigned_#{app_key}",
          severity: if(env == :prod, do: "critical", else: "medium"),
          message: "#{app_key} accepts unsigned webhooks.",
          remediation:
            "Set ALLOW_UNSIGNED_WEBHOOKS=false and configure #{secret_env_name(app_key)}."
        }
      )
      |> maybe_add(
        not allow_unsigned? and secret and env == :prod,
        %{
          id: "webhook_secret_missing_#{app_key}",
          severity: "high",
          message:
            "#{app_key} webhook signature verification is enabled but its secret is missing.",
          remediation: "Configure #{secret_env_name(app_key)} before enabling the webhook."
        }
      )
      |> maybe_add(
        app_key == :telegram and not allow_unsigned? and secret and env != :prod,
        %{
          id: "telegram_webhook_secret_missing",
          severity: "medium",
          message: "Telegram webhook secret path is missing.",
          remediation:
            "Set TELEGRAM_WEBHOOK_SECRET or enable unsigned webhooks only for local development."
        }
      )
    end)
  end

  defp add_api_auth_findings(findings, env) do
    token =
      :maraithon
      |> Application.get_env(:api_auth, [])
      |> Keyword.get(:bearer_token, "")

    findings
    |> maybe_add(blank?(token), %{
      id: "api_bearer_token_missing",
      severity: if(env == :prod, do: "high", else: "medium"),
      message: "API bearer token is missing.",
      remediation: "Set API_BEARER_TOKEN to a high-entropy value."
    })
    |> maybe_add(not blank?(token) and String.length(to_string(token)) < 32, %{
      id: "api_bearer_token_weak",
      severity: if(env == :prod, do: "high", else: "medium"),
      message: "API bearer token is shorter than 32 characters.",
      remediation: "Rotate API_BEARER_TOKEN to a high-entropy value of at least 32 characters."
    })
  end

  defp add_admin_auth_findings(findings, env) do
    config = Application.get_env(:maraithon, :admin_auth, [])
    username = Keyword.get(config, :username, "")
    password = Keyword.get(config, :password, "")

    findings
    |> maybe_add(blank?(username), %{
      id: "admin_username_missing",
      severity: if(env == :prod, do: "high", else: "low"),
      message: "Admin username is missing.",
      remediation: "Set ADMIN_USERNAME or rely only on DB-backed admin sessions where available."
    })
    |> maybe_add(blank?(password), %{
      id: "admin_password_missing",
      severity: if(env == :prod, do: "high", else: "low"),
      message: "Admin password is missing.",
      remediation: "Set ADMIN_PASSWORD to a high-entropy value or disable password fallback."
    })
    |> maybe_add(not blank?(password) and String.length(to_string(password)) < 16, %{
      id: "admin_password_weak",
      severity: if(env == :prod, do: "high", else: "medium"),
      message: "Admin password is shorter than 16 characters.",
      remediation: "Rotate ADMIN_PASSWORD to a longer high-entropy secret."
    })
  end

  defp add_tool_policy_findings(findings) do
    missing_metadata =
      Tools.list()
      |> Enum.filter(&(Tools.policy_metadata_for(&1) in [nil, %{}]))

    unsafe_mutations =
      Tools.list()
      |> Enum.filter(fn tool_name ->
        metadata = Tools.policy_metadata_for(tool_name) || %{}

        metadata.side_effect in ["destructive", "external_send"] and
          metadata.confirmation_required? != true
      end)

    findings
    |> maybe_add(missing_metadata != [], %{
      id: "tool_policy_metadata_missing",
      severity: "high",
      message: "Some actions lack safety metadata: #{Enum.join(missing_metadata, ", ")}.",
      remediation:
        "Add safety metadata before exposing new actions to assistant-controlled surfaces."
    })
    |> maybe_add(unsafe_mutations != [], %{
      id: "tool_policy_confirmation_missing",
      severity: "critical",
      message:
        "Destructive or external-send actions do not require confirmation: #{Enum.join(unsafe_mutations, ", ")}.",
      remediation: "Mark all destructive and external-send actions confirmation_required."
    })
  end

  defp add_file_root_findings(findings, env) do
    roots =
      :maraithon
      |> Application.get_env(Maraithon.Runtime, [])
      |> Keyword.get(:tool_allowed_paths, [])
      |> List.wrap()
      |> Enum.map(&Path.expand(to_string(&1)))

    broad_roots =
      Enum.filter(roots, fn root ->
        root in ["/", Path.expand("~"), Path.expand("/Users"), Path.expand("/Users/kent")]
      end)

    maybe_add(findings, broad_roots != [], %{
      id: "tool_file_roots_too_broad",
      severity: if(env == :prod, do: "critical", else: "high"),
      message: "Tool file roots are too broad: #{Enum.join(broad_roots, ", ")}.",
      remediation: "Constrain TOOL_ALLOWED_PATHS to specific project or working directories."
    })
  end

  defp add_connected_account_findings(findings) do
    counts =
      try do
        ConnectedAccount
        |> where([account], account.status in ["error", "disconnected"])
        |> group_by([account], account.status)
        |> select([account], {account.status, count(account.id)})
        |> Repo.all()
        |> Map.new()
      rescue
        _error -> %{}
      end

    degraded_count = Map.get(counts, "error", 0) + Map.get(counts, "disconnected", 0)

    maybe_add(findings, degraded_count > 0, %{
      id: "connected_accounts_degraded",
      severity: "low",
      message: "#{degraded_count} connected account records are in error or disconnected state.",
      remediation:
        "Use source freshness and connector detail pages to reconnect affected accounts."
    })
  end

  defp add_redaction_findings(findings) do
    sample = %{
      "access_token" => "sk-abcdefghijklmnopqrstuvwxyz123456",
      "authorization" => "Bearer sk-abcdefghijklmnopqrstuvwxyz123456",
      "safe" => "visible"
    }

    encoded = sample |> Redaction.redact() |> inspect()
    leaked? = String.contains?(encoded, "abcdefghijklmnopqrstuvwxyz123456")

    maybe_add(findings, leaked?, %{
      id: "redaction_self_test_failed",
      severity: "critical",
      message: "Redaction self-test leaked a known token-shaped value.",
      remediation: "Fix Maraithon.Redaction before exporting diagnostics or ledger explanations."
    })
  end

  defp maybe_add(findings, true, finding), do: [finding | findings]
  defp maybe_add(findings, _condition, _finding), do: findings

  defp audit_status(findings) do
    cond do
      Enum.any?(findings, &(&1.severity in ["critical", "high"])) -> "fail"
      findings != [] -> "warn"
      true -> "pass"
    end
  end

  defp count_severity(findings, severity), do: Enum.count(findings, &(&1.severity == severity))

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(value), do: to_string(value) |> blank?()

  defp normalize_env(env) when env in [:dev, :test, :prod], do: env

  defp normalize_env(env) when is_binary(env) do
    case String.trim(env) do
      "prod" -> :prod
      "test" -> :test
      "dev" -> :dev
      _ -> current_env()
    end
  end

  defp normalize_env(_env), do: current_env()

  defp current_env do
    case Code.ensure_loaded(Mix) do
      {:module, Mix} ->
        if function_exported?(Mix, :env, 0), do: Mix.env(), else: :prod

      _ ->
        :prod
    end
  end

  defp secret_env_name(:github), do: "GITHUB_WEBHOOK_SECRET"
  defp secret_env_name(:slack), do: "SLACK_SIGNING_SECRET"
  defp secret_env_name(:whatsapp), do: "WHATSAPP_APP_SECRET"
  defp secret_env_name(:linear), do: "LINEAR_WEBHOOK_SECRET"
  defp secret_env_name(:telegram), do: "TELEGRAM_WEBHOOK_SECRET"
end
