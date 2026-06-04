#!/usr/bin/env bash

load_maraithon_fly_env() {
  local deploy_env_file="${MARAITHON_DEPLOY_ENV_FILE:-${HOME}/.config/maraithon/fly-prod.env}"

  if [[ -f "${deploy_env_file}" ]]; then
    # Keep production verification independent from the active Fly account.
    # shellcheck disable=SC1090
    source "${deploy_env_file}"
  fi

  export MARAITHON_FLY_APP="${MARAITHON_FLY_APP:-${FLY_APP:-maraithon}}"
  export FLY_APP="${MARAITHON_FLY_APP}"

  if [[ -z "${FLY_API_TOKEN:-}" ]]; then
    echo "FLY_API_TOKEN is required for production Fly operations." >&2
    echo "Set it in ${deploy_env_file} or export it before running production verification." >&2
    exit 1
  fi

  export FLY_API_TOKEN
}

load_maraithon_fly_env

generate_maraithon_magic_token() {
  local fly_app="$1"
  local email="$2"
  local user_agent="${3:-mobile-verification-loop}"
  local eval_code

  eval_code="Application.load(:maraithon); Application.ensure_all_started(:ssl); Application.ensure_all_started(:postgrex); Application.ensure_all_started(:ecto_sql); {:ok, _} = Maraithon.Repo.start_link(); case Maraithon.Accounts.request_magic_link(\"${email}\", user_agent: \"${user_agent}\") do {:ok, %{token: token}} -> IO.puts(token); other -> IO.inspect(other); System.halt(1) end"

  flyctl ssh console -a "${fly_app}" -C "/app/bin/maraithon eval '${eval_code}'" |
    awk '/^[A-Za-z0-9_-]{40,}$/ { print; found=1; exit } END { if (!found) exit 1 }'
}

generate_maraithon_magic_code() {
  local fly_app="$1"
  local email="$2"
  local user_agent="${3:-mobile-verification-loop}"
  local eval_code

  eval_code="Application.load(:maraithon); Application.ensure_all_started(:ssl); Application.ensure_all_started(:postgrex); Application.ensure_all_started(:ecto_sql); {:ok, _} = Maraithon.Repo.start_link(); case Maraithon.Accounts.request_magic_code(\"${email}\", user_agent: \"${user_agent}\") do {:ok, %{code: code}} -> IO.puts(code); other -> IO.inspect(other); System.halt(1) end"

  flyctl ssh console -a "${fly_app}" -C "/app/bin/maraithon eval '${eval_code}'" |
    awk '/^[A-Z0-9]{4}-[A-Z0-9]{4}$/ { print; found=1; exit } END { if (!found) exit 1 }'
}
