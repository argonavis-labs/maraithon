defmodule Maraithon.DurablePayloadOperatorAuthorityAdversarialTest do
  use Maraithon.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Repo
  alias Maraithon.Runtime.Coordination.Protocol, as: CoordinationProtocol
  alias Maraithon.Vault

  @moduletag database_role: :session
  @moduletag timeout: 180_000

  @evidence [
    evidence_id: "test:durable-payload:operator-row-authority",
    evidence_digest: :crypto.hash(:sha256, "operator row authority evidence"),
    activated_by: "operator-row-authority@example.test",
    revision: String.duplicate("e", 40)
  ]

  @source_tables ~w(
    connected_accounts oauth_tokens local_browser_visits local_calendar_events
    local_files memory_items effects agent_directives events agent_run_steps
    telegram_conversation_turns telegram_conversations telegram_assistant_runs
    telegram_assistant_steps telegram_prepared_actions agent_runs operator_events
    user_memory_profiles operator_memory_summaries background_jobs scheduled_jobs
    runtime_ingress_receipts agent_work_results snapshots
  )

  @binding_targets [
    {"effects", :payload},
    {"agent_directives", :payload},
    {"events", :payload},
    {"agent_run_steps", :payload},
    {"telegram_conversation_turns", :payload},
    {"telegram_conversations", :payload},
    {"telegram_assistant_runs", :payload},
    {"telegram_assistant_steps", :payload},
    {"telegram_prepared_actions", :payload},
    {"agent_runs", :payload},
    {"operator_events", :payload},
    {"user_memory_profiles", :payload},
    {"operator_memory_summaries", :payload},
    {"background_jobs", :payload},
    {"scheduled_jobs", :payload},
    {"runtime_ingress_receipts", :payload},
    {"agent_work_results", :payload},
    {"snapshots", :payload},
    {"agent_work_results", :authority}
  ]

  @marker_settings %{
    binding: {"maraithon.binding_key_rotation", "BINDING_KEY_ROTATION_V1"},
    vault: {"maraithon.vault_reencryption", "VAULT_REENCRYPT_V1"},
    contraction: {"maraithon.payload_contraction", "STOPPED_FLEET_EVIDENCE_V1"}
  }

  setup do
    set_role!(:runtime)
    assert ProtocolCutover.mode() == :legacy

    assert {:ok, status} = CoordinationProtocol.attest_effect_activation_evidence(@evidence)
    assert status in [:attested, :already_attested]

    set_role!(:runtime)
    :ok
  end

  test "ordinary runtime DML does not evaluate an unexecutable operator helper" do
    refute function_privilege?(
             "maraithon_runtime",
             "public.durable_payload_operator_row_mutation_authorized(regclass,text,jsonb,jsonb)"
           )

    first = encrypt!("ordinary runtime source write")
    second = encrypt!("ordinary runtime source rewrite")
    id = Ecto.UUID.generate()

    assert %Postgrex.Result{num_rows: 1} =
             SQL.query!(
               Repo,
               """
               INSERT INTO public.local_browser_visits (
                 id, user_id, device_id, browser, url, title, inserted_at, updated_at
               ) VALUES (
                 $1::uuid, $2, $3::uuid, 'chrome', $4, $5,
                 timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp())
               )
               """,
               [
                 uuid(id),
                 "operator-guard-runtime-#{id}",
                 uuid(Ecto.UUID.generate()),
                 "https://example.test/runtime/#{id}",
                 first
               ]
             )

    assert %Postgrex.Result{num_rows: 1} =
             SQL.query!(
               Repo,
               "UPDATE local_browser_visits SET title = $2 WHERE id = $1::uuid",
               [uuid(id), second]
             )

    assert [[^second]] =
             SQL.query!(Repo, "SELECT title FROM local_browser_visits WHERE id = $1::uuid", [
               uuid(id)
             ]).rows
  end

  test "the operator guard is ENABLE ALWAYS on the exact 24-source registry" do
    rows =
      SQL.query!(
        Repo,
        """
        SELECT relation.relname, trigger.tgenabled::text, trigger.tgtype::integer,
               function.proname
        FROM pg_catalog.pg_trigger AS trigger
        JOIN pg_catalog.pg_class AS relation ON relation.oid = trigger.tgrelid
        JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        JOIN pg_catalog.pg_proc AS function ON function.oid = trigger.tgfoid
        WHERE namespace.nspname = 'public'
          AND trigger.tgname = 'guard_durable_payload_operator_mutation_trigger'
          AND NOT trigger.tgisinternal
        ORDER BY relation.relname
        """,
        []
      ).rows

    assert length(rows) == 24

    assert rows ==
             @source_tables
             |> Enum.sort()
             |> Enum.map(fn table ->
               # ROW | BEFORE | INSERT | DELETE | UPDATE = 1 + 2 + 4 + 8 + 16.
               [table, "A", 31, "guard_durable_payload_operator_source_mutation"]
             end)
  end

  test "zero-argument compatibility predicate is unavailable to every operational role" do
    for role <- [
          "maraithon_runtime",
          "maraithon_payload_verifier",
          "maraithon_incident_operator",
          "maraithon_activation_operator"
        ] do
      refute function_privilege?(
               role,
               "public.durable_payload_operator_mutation_authorized()"
             )
    end

    assert function_privilege?(
             "maraithon_incident_operator",
             "public.durable_payload_operator_row_mutation_authorized(regclass,text,jsonb,jsonb)"
           )

    assert function_privilege?(
             "maraithon_activation_operator",
             "public.durable_payload_operator_row_mutation_authorized(regclass,text,jsonb,jsonb)"
           )

    assert_postgres_code("42501", :incident, [], fn ->
      SQL.query!(Repo, "SELECT public.durable_payload_operator_mutation_authorized()", [])
    end)

    assert_postgres_code("42501", :activation, [], fn ->
      SQL.query!(Repo, "SELECT public.durable_payload_operator_mutation_authorized()", [])
    end)

    in_operator_role!(:migrator, [], fn ->
      assert [[false]] =
               SQL.query!(
                 Repo,
                 "SELECT public.durable_payload_operator_mutation_authorized()",
                 []
               ).rows
    end)
  end

  test "all six Vault-only sources require the Vault marker and preserve field presence" do
    activate_exact_pair!()
    user_id = seed_user!()
    original = encrypt!("operator guard original")
    replacement = encrypt!("operator guard replacement")
    targets = seed_vault_only_sources!(user_id, original)

    Enum.each(targets, fn target ->
      update_sql =
        "UPDATE public.#{target.table} SET #{target.column} = $2 WHERE id::text = $1"

      assert_guard_rejected!([], fn ->
        SQL.query!(Repo, update_sql, [target.id, replacement])
      end)

      assert_guard_rejected!([:binding], fn ->
        SQL.query!(Repo, update_sql, [target.id, replacement])
      end)

      in_operator_role!(:incident, [:vault], fn ->
        assert %Postgrex.Result{num_rows: 1} =
                 SQL.query!(Repo, update_sql, [target.id, replacement])
      end)

      assert_guard_rejected!([:vault], fn ->
        SQL.query!(Repo, update_sql, [target.id, nil])
      end)

      assert [[^replacement]] =
               SQL.query!(
                 Repo,
                 "SELECT #{target.column} FROM public.#{target.table} WHERE id::text = $1",
                 [target.id]
               ).rows
    end)
  end

  test "every Binding target rejects Vault and mixed markers" do
    activate_exact_pair!()

    in_operator_role!(:incident, [:binding], fn ->
      Enum.each(@binding_targets, fn {table, binding} ->
        {old_row, new_row} = binding_rows(table, binding)
        assert row_authorized?(table, "UPDATE", old_row, new_row)
      end)
    end)

    for markers <- [[:vault], [:binding, :vault], []] do
      in_operator_role!(:incident, markers, fn ->
        Enum.each(@binding_targets, fn {table, binding} ->
          {old_row, new_row} = binding_rows(table, binding)
          refute row_authorized?(table, "UPDATE", old_row, new_row)
        end)
      end)
    end
  end

  test "activation accepts only the six reviewed contraction projections" do
    shapes = contraction_shapes()

    in_operator_role!(:activation, [:contraction], fn ->
      Enum.each(shapes, fn shape ->
        assert row_authorized?(shape.table, "UPDATE", shape.old, shape.new), shape.table

        unrelated_new = Map.put(shape.new, shape.unrelated, "operator-tamper")

        refute row_authorized?(shape.table, "UPDATE", shape.old, unrelated_new),
               "#{shape.table} accepted unrelated #{shape.unrelated} mutation"
      end)
    end)

    for markers <- [[], [:binding], [:vault], [:contraction, :binding], [:contraction, :vault]] do
      in_operator_role!(:activation, markers, fn ->
        Enum.each(shapes, fn shape ->
          refute row_authorized?(shape.table, "UPDATE", shape.old, shape.new),
                 "#{shape.table} accepted markers #{inspect(markers)}"
        end)
      end)
    end
  end

  test "raw INSERT and DELETE are outside row authority and role ACLs" do
    activate_exact_pair!()
    id = Ecto.UUID.generate()
    ciphertext = encrypt!("raw operation rejection")

    in_operator_role!(:incident, [:vault], fn ->
      refute row_authorized?(
               "local_browser_visits",
               "INSERT",
               nil,
               %{"id" => id, "title" => bytea_json(ciphertext)}
             )

      refute row_authorized?(
               "local_browser_visits",
               "DELETE",
               %{"id" => id, "title" => bytea_json(ciphertext)},
               nil
             )
    end)

    assert_postgres_code("42501", :incident, [:vault], fn ->
      SQL.query!(
        Repo,
        """
        INSERT INTO public.local_browser_visits (
          id, user_id, device_id, browser, url, title, inserted_at, updated_at
        ) VALUES (
          $1::uuid, $2, $3::uuid, 'chrome', $4, $5,
          timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp())
        )
        """,
        [
          uuid(id),
          "operator-guard-raw-#{id}",
          uuid(Ecto.UUID.generate()),
          "https://example.test/raw/#{id}",
          ciphertext
        ]
      )
    end)

    set_role!(:runtime)
    insert_runtime_visit!(id, ciphertext)

    assert_postgres_code("42501", :incident, [:vault], fn ->
      SQL.query!(Repo, "DELETE FROM local_browser_visits WHERE id = $1::uuid", [uuid(id)])
    end)
  end

  defp contraction_shapes do
    binding = %{
      "payload_binding_version" => 1,
      "payload_binding_key_tag" => "binding.current",
      "payload_binding_mac" => bytea_json(:crypto.hash(:sha256, "contraction binding"))
    }

    [
      %{
        table: "effects",
        unrelated: "status",
        old: %{
          "id" => "effect-row",
          "status" => "completed",
          "params" => %{"secret" => true},
          "result" => %{"secret" => true}
        },
        new:
          Map.merge(binding, %{
            "id" => "effect-row",
            "status" => "completed",
            "params" => %{"redacted" => true},
            "params_ciphertext" => "ciphertext",
            "result" => nil,
            "result_ciphertext" => "ciphertext",
            "error" => nil,
            "payload_encryption_version" => 1,
            "updated_at" => "2026-01-01T00:00:00Z"
          })
      },
      %{
        table: "agent_directives",
        unrelated: "status",
        old: %{
          "id" => "directive-row",
          "status" => "completed",
          "payload" => %{"secret" => true}
        },
        new:
          Map.merge(binding, %{
            "id" => "directive-row",
            "status" => "completed",
            "payload" => %{"redacted" => true},
            "payload_ciphertext" => "ciphertext",
            "payload_encryption_version" => 1,
            "updated_at" => "2026-01-01T00:00:00Z"
          })
      },
      %{
        table: "events",
        unrelated: "event_type",
        old: %{
          "id" => "event-row",
          "event_type" => "observed",
          "payload" => %{"secret" => true}
        },
        new:
          Map.merge(binding, %{
            "id" => "event-row",
            "event_type" => "observed",
            "payload" => %{},
            "payload_ciphertext" => "ciphertext",
            "payload_encryption_version" => 1,
            "spend_total_cost" => 0,
            "spend_input_tokens" => 0,
            "spend_output_tokens" => 0,
            "spend_llm_calls" => 0
          })
      },
      %{
        table: "agent_run_steps",
        unrelated: "status",
        old: %{
          "id" => "step-row",
          "status" => "completed",
          "request_payload" => %{"secret" => true},
          "response_payload" => %{"secret" => true}
        },
        new:
          Map.merge(binding, %{
            "id" => "step-row",
            "status" => "completed",
            "request_payload" => %{},
            "request_payload_ciphertext" => "ciphertext",
            "response_payload" => %{},
            "response_payload_ciphertext" => "ciphertext",
            "payload_encryption_version" => 1,
            "updated_at" => "2026-01-01T00:00:00Z"
          })
      },
      %{
        table: "background_jobs",
        unrelated: "status",
        old: %{
          "id" => "background-row",
          "status" => "pending",
          "payload" => %{"request_id" => Ecto.UUID.generate()},
          "result" => nil
        },
        new:
          Map.merge(binding, %{
            "id" => "background-row",
            "status" => "pending",
            "payload" => %{},
            "payload_ciphertext" => "ciphertext",
            "result" => %{},
            "result_ciphertext" => "ciphertext",
            "payload_encryption_version" => 1,
            "updated_at" => "2026-01-01T00:00:00Z"
          })
      },
      %{
        table: "snapshots",
        unrelated: "state_name",
        old: %{
          "id" => 42,
          "state_name" => "working",
          "state_data" => %{"secret" => true},
          "budget" => %{"secret" => true}
        },
        new:
          Map.merge(binding, %{
            "id" => 42,
            "state_name" => "working",
            "state_data" => %{},
            "state_data_ciphertext" => "ciphertext",
            "budget" => %{},
            "budget_ciphertext" => "ciphertext",
            "payload_encryption_version" => 1
          })
      }
    ]
  end

  defp binding_rows(table, :payload) do
    base = %{
      "id" => "#{table}-row",
      "payload_binding_version" => 1,
      "payload_binding_key_tag" => "binding.old",
      "payload_binding_mac" => bytea_json(:crypto.hash(:sha256, "#{table}:old"))
    }

    {base,
     %{
       base
       | "payload_binding_key_tag" => "binding.new",
         "payload_binding_mac" => bytea_json(:crypto.hash(:sha256, "#{table}:new"))
     }}
  end

  defp binding_rows(table, :authority) do
    base = %{
      "id" => "#{table}-authority-row",
      "result_digest_version" => 1,
      "result_digest_key_tag" => "binding.old",
      "result_digest" => bytea_json(:crypto.hash(:sha256, "#{table}:authority:old"))
    }

    {base,
     %{
       base
       | "result_digest_key_tag" => "binding.new",
         "result_digest" => bytea_json(:crypto.hash(:sha256, "#{table}:authority:new"))
     }}
  end

  defp seed_user! do
    id = "operator-guard-user-#{System.unique_integer([:positive, :monotonic])}"

    SQL.query!(
      Repo,
      """
      INSERT INTO public.users (id, email, is_admin, inserted_at, updated_at)
      VALUES ($1, $2, false, timezone('UTC', clock_timestamp()),
              timezone('UTC', clock_timestamp()))
      """,
      [id, "#{id}@example.test"]
    )

    id
  end

  defp seed_vault_only_sources!(user_id, ciphertext) do
    connected_id =
      returning_id!(
        """
        INSERT INTO public.connected_accounts (
          user_id, provider, status, access_token, inserted_at, updated_at
        ) VALUES (
          $1, $2, 'connected', $3, timezone('UTC', clock_timestamp()),
          timezone('UTC', clock_timestamp())
        ) RETURNING id::text
        """,
        [user_id, "operator-guard-connected", ciphertext]
      )

    oauth_id =
      returning_id!(
        """
        INSERT INTO public.oauth_tokens (
          user_id, provider, access_token, inserted_at, updated_at
        ) VALUES (
          $1, $2, $3, timezone('UTC', clock_timestamp()),
          timezone('UTC', clock_timestamp())
        ) RETURNING id::text
        """,
        [user_id, "operator-guard-oauth", ciphertext]
      )

    browser_id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO public.local_browser_visits (
        id, user_id, device_id, browser, url, title, inserted_at, updated_at
      ) VALUES (
        $1::uuid, $2, $3::uuid, 'chrome', $4, $5,
        timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp())
      )
      """,
      [
        uuid(browser_id),
        user_id,
        uuid(Ecto.UUID.generate()),
        "https://example.test/operator-guard/browser",
        ciphertext
      ]
    )

    calendar_id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO public.local_calendar_events (
        id, user_id, device_id, source, title, inserted_at, updated_at
      ) VALUES (
        $1::uuid, $2, $3::uuid, 'calendar', $4,
        timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp())
      )
      """,
      [uuid(calendar_id), user_id, uuid(Ecto.UUID.generate()), ciphertext]
    )

    file_id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO public.local_files (
        id, user_id, device_id, source, path, filename, inserted_at, updated_at
      ) VALUES (
        $1::uuid, $2, $3::uuid, 'files', '~/operator-guard.txt', $4,
        timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp())
      )
      """,
      [uuid(file_id), user_id, uuid(Ecto.UUID.generate()), ciphertext]
    )

    memory_id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO public.memory_items (
        id, user_id, status, kind, scope, title, content, source, author_type,
        metadata, inserted_at, updated_at
      ) VALUES (
        $1::uuid, $2, 'active', 'fact', 'user', 'Operator guard memory', $3,
        'manual', 'user', $4, timezone('UTC', clock_timestamp()),
        timezone('UTC', clock_timestamp())
      )
      """,
      [uuid(memory_id), user_id, ciphertext, encrypt!("{}")]
    )

    [
      %{table: "connected_accounts", column: "access_token", id: connected_id},
      %{table: "oauth_tokens", column: "access_token", id: oauth_id},
      %{table: "local_browser_visits", column: "title", id: browser_id},
      %{table: "local_calendar_events", column: "title", id: calendar_id},
      %{table: "local_files", column: "filename", id: file_id},
      %{table: "memory_items", column: "content", id: memory_id}
    ]
  end

  defp insert_runtime_visit!(id, ciphertext) do
    SQL.query!(
      Repo,
      """
      INSERT INTO public.local_browser_visits (
        id, user_id, device_id, browser, url, title, inserted_at, updated_at
      ) VALUES (
        $1::uuid, $2, $3::uuid, 'chrome', $4, $5,
        timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp())
      )
      """,
      [
        uuid(id),
        "operator-guard-raw-#{id}",
        uuid(Ecto.UUID.generate()),
        "https://example.test/raw/#{id}",
        ciphertext
      ]
    )
  end

  defp returning_id!(sql, params) do
    assert [[id]] = SQL.query!(Repo, sql, params).rows
    id
  end

  defp row_authorized?(table, operation, old_row, new_row) do
    assert [[authorized]] =
             SQL.query!(
               Repo,
               """
               SELECT public.durable_payload_operator_row_mutation_authorized(
                 $1::text::regclass, $2, $3::jsonb, $4::jsonb
               )
               """,
               ["public.#{table}", operation, old_row, new_row]
             ).rows

    authorized
  end

  defp function_privilege?(role, signature) do
    assert [[allowed]] =
             SQL.query!(
               Repo,
               "SELECT pg_catalog.has_function_privilege($1, $2, 'EXECUTE')",
               [role, signature]
             ).rows

    allowed
  end

  defp assert_guard_rejected!(markers, fun) do
    error = assert_postgres_code("42501", :incident, markers, fun)

    assert error.postgres.message =~
             "durable payload operator mutation is outside reviewed authority"
  end

  defp assert_postgres_code(code, role, markers, fun) do
    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(
          fn ->
            set_role!(role)
            clear_operator_markers!()
            put_operator_markers!(markers)
            fun.()
          end,
          mode: :savepoint
        )
      end

    assert error.postgres.pg_code == code,
           "expected SQLSTATE #{code}, got #{inspect(error.postgres)}"

    error
  end

  defp in_operator_role!(role, markers, fun) do
    case Repo.transaction(
           fn ->
             set_role!(role)
             clear_operator_markers!()
             put_operator_markers!(markers)

             try do
               fun.()
             after
               clear_operator_markers!()
               set_role!(:runtime)
             end
           end,
           mode: :savepoint
         ) do
      {:ok, value} -> value
      {:error, reason} -> flunk("role-scoped transaction failed: #{inspect(reason)}")
    end
  end

  defp clear_operator_markers! do
    Enum.each(@marker_settings, fn {_name, {setting, _value}} ->
      SQL.query!(Repo, "SELECT pg_catalog.set_config($1, '', true)", [setting])
    end)
  end

  defp put_operator_markers!(markers) do
    Enum.each(markers, fn marker ->
      {setting, value} = Map.fetch!(@marker_settings, marker)
      SQL.query!(Repo, "SELECT pg_catalog.set_config($1, $2, true)", [setting, value])
    end)
  end

  defp activate_exact_pair! do
    assert {:ok, effect_status} =
             ProtocolCutover.activate(
               [confirmation: ProtocolCutover.activation_confirmation()] ++ @evidence
             )

    assert effect_status in [:activated, :already_active]

    assert {:ok, runtime_status} =
             CoordinationProtocol.activate(
               [confirmation: CoordinationProtocol.activation_confirmation()] ++ @evidence
             )

    assert runtime_status in [:activated, :already_active]
    set_role!(:runtime)
    :ok
  end

  defp set_role!(role) do
    SQL.query!(Repo, "RESET ROLE", [])

    role_name =
      case role do
        :runtime -> "maraithon_runtime"
        :migrator -> "maraithon_migrator"
        :incident -> "maraithon_incident_operator"
        :activation -> "maraithon_activation_operator"
      end

    SQL.query!(Repo, "SET LOCAL ROLE #{role_name}", [])
  end

  defp encrypt!(plaintext) do
    assert {:ok, ciphertext} = Vault.encrypt(plaintext)
    ciphertext
  end

  defp bytea_json(binary) when is_binary(binary),
    do: "\\x" <> Base.encode16(binary, case: :lower)

  defp uuid(value), do: Ecto.UUID.dump!(value)
end
