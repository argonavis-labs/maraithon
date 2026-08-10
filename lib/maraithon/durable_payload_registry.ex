defmodule Maraithon.DurablePayloadRegistry do
  @moduledoc """
  Closed registry for authenticated durable payload sources.

  The registry is shared by verification, Vault rotation, and tests which
  compare each schema's `payload_binding_spec/0`. Entries are code-reviewed;
  no table or column identifier is accepted from user input.
  """

  @sources [
    %{
      table: "effects",
      module: Maraithon.Effects.Effect,
      identity: [:id],
      scope: [:owner_user_id, :agent_id],
      purge: :payload_purged_at,
      version: :payload_encryption_version,
      fields: [
        {:params, :params_ciphertext, :map, 200_000, true},
        {:result, :result_ciphertext, :map, 600_000, false}
      ]
    },
    %{
      table: "agent_directives",
      module: Maraithon.Runtime.AgentDirective,
      identity: [:id],
      scope: [:user_id, :agent_id],
      purge: :payload_purged_at,
      version: :payload_encryption_version,
      fields: [{:payload, :payload_ciphertext, :map, 180_000, true}]
    },
    %{
      table: "events",
      module: Maraithon.Events.Event,
      identity: [:agent_id, :sequence_num],
      scope: [:agent_id],
      purge: :payload_purged_at,
      version: :payload_encryption_version,
      fields: [{:payload, :payload_ciphertext, :map, 700_000, true}]
    },
    %{
      table: "agent_run_steps",
      module: Maraithon.Agents.AgentRunStep,
      identity: [:id],
      scope: [:agent_id, :agent_run_id],
      purge: :payload_purged_at,
      version: :payload_encryption_version,
      fields: [
        {:request_payload, :request_payload_ciphertext, :map, 300_000, true},
        {:response_payload, :response_payload_ciphertext, :map, 700_000, true}
      ]
    },
    %{
      table: "telegram_conversation_turns",
      module: Maraithon.TelegramConversations.Turn,
      identity: [:id],
      scope: [:conversation_id],
      purge: :content_scrubbed_at,
      version: :payload_encryption_version,
      fields: [
        {:text, :text_ciphertext, :binary, 70_000, true},
        {:structured_data, :structured_data_ciphertext, :map, 200_000, true}
      ]
    },
    %{
      table: "telegram_conversations",
      module: Maraithon.TelegramConversations.Conversation,
      identity: [:id],
      scope: [:user_id],
      purge: :content_scrubbed_at,
      version: :payload_encryption_version,
      fields: [
        {:summary, :summary_ciphertext, :binary, 40_000, false},
        {:historical_summary, :historical_summary_ciphertext, :binary, 40_000, false}
      ]
    },
    %{
      table: "telegram_assistant_runs",
      module: Maraithon.TelegramAssistant.Run,
      identity: [:id],
      scope: [:user_id, :conversation_id],
      purge: :payload_purged_at,
      version: :payload_encryption_version,
      fields: [
        {:prompt_snapshot, :prompt_snapshot_ciphertext, :map, 700_000, true},
        {:result_summary, :result_summary_ciphertext, :map, 300_000, true}
      ]
    },
    %{
      table: "telegram_assistant_steps",
      module: Maraithon.TelegramAssistant.Step,
      identity: [:id],
      scope: [:run_id],
      purge: :payload_purged_at,
      version: :payload_encryption_version,
      fields: [
        {:request_payload, :request_payload_ciphertext, :map, 300_000, true},
        {:response_payload, :response_payload_ciphertext, :map, 700_000, true}
      ]
    },
    %{
      table: "telegram_prepared_actions",
      module: Maraithon.TelegramAssistant.PreparedAction,
      identity: [:id],
      scope: [:user_id, :conversation_id, :run_id],
      purge: :payload_purged_at,
      version: :payload_encryption_version,
      fields: [
        {:payload, :payload_ciphertext, :map, 600_000, true},
        {:preview_text, :preview_text_ciphertext, :binary, 12_000, true}
      ]
    },
    %{
      table: "agent_runs",
      module: Maraithon.Agents.AgentRun,
      identity: [:id],
      scope: [:user_id, :agent_id],
      purge: :private_payload_purged_at,
      version: :private_payload_encryption_version,
      fields: [
        {:trigger, :trigger_ciphertext, :map, 300_000, true},
        {:metadata, :metadata_ciphertext, :map, 160_000, true}
      ]
    },
    %{
      table: "operator_events",
      module: Maraithon.OperatorEvents.OperatorEvent,
      identity: [:id],
      scope: [:user_id, :project_id],
      purge: :payload_purged_at,
      version: :payload_encryption_version,
      fields: [
        {:payload, :payload_ciphertext, :map, 300_000, true},
        {:metadata, :metadata_ciphertext, :map, 160_000, true}
      ]
    },
    %{
      table: "user_memory_profiles",
      module: Maraithon.UserMemory.Profile,
      identity: [:id],
      scope: [:user_id],
      purge: :content_erased_at,
      version: :payload_encryption_version,
      fields: [
        {:summary, :summary_ciphertext, :binary, 8_000, true},
        {:profile, :profile_ciphertext, :map, 80_000, true}
      ]
    },
    %{
      table: "operator_memory_summaries",
      module: Maraithon.OperatorMemory.Summary,
      identity: [:id],
      scope: [:user_id],
      purge: :content_erased_at,
      version: :payload_encryption_version,
      fields: [{:content, :content_ciphertext, :binary, 8_000, true}]
    },
    %{
      table: "background_jobs",
      module: Maraithon.Runtime.BackgroundJob,
      identity: [:id],
      scope: [:user_id],
      purge: :payload_purged_at,
      version: :payload_encryption_version,
      fields: [
        {:payload, :payload_ciphertext, :map, 700_000, true},
        {:result, :result_ciphertext, :map, 300_000, true}
      ]
    },
    %{
      table: "scheduled_jobs",
      module: Maraithon.Runtime.ScheduledJob,
      identity: [:id],
      scope: [:agent_id],
      purge: :payload_purged_at,
      version: :payload_encryption_version,
      fields: [{:payload, :payload_ciphertext, :map, 200_000, true}]
    },
    %{
      table: "runtime_ingress_receipts",
      module: Maraithon.Runtime.IngressReceipt,
      identity: [:id],
      scope: [:user_id, :agent_id, :connected_account_id],
      purge: :payload_purged_at,
      version: :payload_encryption_version,
      fields: [{:payload, :payload_ciphertext, :map, 160_000, true}]
    },
    %{
      table: "snapshots",
      module: Maraithon.Runtime.Snapshot,
      identity: [:id],
      scope: [:agent_id, :sequence_num, :schema_version, :state_name],
      purge: :payload_purged_at,
      version: :payload_encryption_version,
      fields: [
        {:state_data, :state_data_ciphertext, :map, 1_100_000, true},
        {:budget, :budget_ciphertext, :map, 1_100_000, true}
      ]
    },
    %{
      table: "agent_work_results",
      module: Maraithon.Runtime.AgentWorkResult,
      identity: [:id],
      scope: [:user_id, :agent_id, :agent_directive_id, :agent_run_id],
      purge: :result_purged_at,
      version: :payload_encryption_version,
      fields: [{:result, :result_ciphertext, :map, 160_000, true}]
    }
  ]

  @doc "All registered sources in canonical lock/verification order."
  def all, do: @sources

  @doc "Registered table identifiers."
  def tables, do: Enum.map(@sources, & &1.table)

  @doc "Fetches a reviewed source; arbitrary SQL identifiers are rejected."
  def fetch(table) when is_binary(table) do
    case Enum.find(@sources, &(&1.table == table)) do
      nil -> :error
      source -> {:ok, Map.merge(source, locator(source.identity))}
    end
  end

  def fetch(_table), do: :error

  defp locator([:id]) do
    %{identity_sql: "source.id::text", report_sql: "source.id::text", order_sql: "source.id"}
  end

  defp locator([:agent_id, :sequence_num]) do
    %{
      identity_sql:
        "'[' || to_json(source.agent_id::text)::text || ',' || " <>
          "to_json(source.sequence_num::text)::text || ']'",
      report_sql: "source.id::text",
      order_sql: "source.inserted_at, source.id"
    }
  end

  @doc "Every authenticated binding target, including the AgentWorkResult authority MAC."
  def binding_targets do
    payload_targets =
      Enum.map(@sources, fn source ->
        Map.merge(source, %{
          binding_name: "payload",
          binding_table: source.table,
          binding_version_column: "payload_binding_version",
          binding_key_tag_column: "payload_binding_key_tag",
          binding_mac_column: "payload_binding_mac",
          identity_encoding: :context
        })
      end)

    authority =
      @sources
      |> Enum.find(&(&1.table == "agent_work_results"))
      |> Map.merge(%{
        binding_name: "authority",
        binding_table: "agent_work_result_authority",
        binding_version_column: "result_digest_version",
        binding_key_tag_column: "result_digest_key_tag",
        binding_mac_column: "result_digest",
        identity_encoding: :scalar
      })

    payload_targets ++ [authority]
  end

  @doc "Fetches one reviewed binding target; arbitrary identifiers are rejected."
  def fetch_binding_target(table, binding_name)
      when is_binary(table) and binding_name in ["payload", "authority"] do
    case Enum.find(binding_targets(), fn target ->
           target.table == table and target.binding_name == binding_name
         end) do
      nil -> :error
      target -> {:ok, Map.merge(target, locator(target.identity))}
    end
  end

  def fetch_binding_target(_table, _binding_name), do: :error

  @doc "Every registered Cloak ciphertext column."
  def ciphertext_columns do
    for source <- @sources,
        {_field, column, _type, max_bytes, _required} <- source.fields do
      %{table: source.table, column: Atom.to_string(column), max_bytes: max_bytes}
    end
  end
end
