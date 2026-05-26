#!/usr/bin/env bash

generate_maraithon_magic_token() {
  local fly_app="$1"
  local email="$2"
  local user_agent="${3:-mobile-verification-loop}"
  local eval_code

  eval_code="Application.load(:maraithon); Application.ensure_all_started(:ssl); Application.ensure_all_started(:postgrex); Application.ensure_all_started(:ecto_sql); {:ok, _} = Maraithon.Repo.start_link(); case Maraithon.Accounts.request_magic_link(\"${email}\", user_agent: \"${user_agent}\") do {:ok, %{token: token}} -> IO.puts(token); other -> IO.inspect(other); System.halt(1) end"

  flyctl ssh console -a "${fly_app}" -C "/app/bin/maraithon eval '${eval_code}'" |
    awk '/^[A-Za-z0-9_-]{40,}$/ { print; found=1; exit } END { if (!found) exit 1 }'
}
