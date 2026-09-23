defmodule Maraithon.Repo.Migrations.CreateTodoTrainingDataset do
  use Ecto.Migration

  def change do
    create table(:todo_training_runs, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :version, :integer, null: false, default: 1
      add :status, :string, null: false, default: "pending"
      add :candidate_count, :integer, null: false
      add :payload, :binary, null: false
      add :payload_hash, :string, null: false
      add :result, :binary
      add :result_hash, :string
      add :completed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:todo_training_runs, [:user_id, :id])
    create index(:todo_training_runs, [:user_id, :inserted_at, :id])
    create index(:todo_training_runs, [:status, :inserted_at])

    create constraint(:todo_training_runs, :todo_training_run_status,
             check:
               "status IN ('pending', 'applied', 'failed', 'abandoned') AND candidate_count > 0"
           )

    create table(:todo_training_examples, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :run_id, :uuid, null: false
      add :todo_id, references(:todos, type: :uuid, on_delete: :delete_all)
      add :candidate_index, :integer, null: false
      add :action, :string, null: false
      add :group_key, :string, null: false
      add :payload, :binary, null: false
      add :payload_hash, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:todo_training_examples, [:user_id, :id])
    create unique_index(:todo_training_examples, [:run_id, :candidate_index])
    create index(:todo_training_examples, [:user_id, :todo_id, :inserted_at])
    create index(:todo_training_examples, [:user_id, :inserted_at, :id])
    create index(:todo_training_examples, [:user_id, :group_key])

    execute(
      """
      ALTER TABLE todo_training_examples ADD CONSTRAINT todo_training_examples_run_scope
      FOREIGN KEY (user_id, run_id) REFERENCES todo_training_runs(user_id, id) ON DELETE CASCADE
      """,
      "ALTER TABLE todo_training_examples DROP CONSTRAINT todo_training_examples_run_scope"
    )

    create constraint(:todo_training_examples, :todo_training_example_action,
             check:
               "action IN ('create', 'update', 'skip', 'unresolved') AND candidate_index >= 0"
           )

    create table(:todo_training_feedback, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :todo_id, references(:todos, type: :uuid, on_delete: :delete_all)
      add :example_id, :uuid

      add :learning_event_id,
          references(:todo_learning_events, type: :uuid, on_delete: :delete_all)

      add :event, :string, null: false
      add :actor, :string, null: false
      add :label, :string, null: false
      add :strength, :string, null: false
      add :dedupe_key, :string, null: false
      add :payload, :binary, null: false
      add :payload_hash, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    execute(
      """
      ALTER TABLE todo_training_feedback ADD CONSTRAINT todo_training_feedback_example_scope
      FOREIGN KEY (user_id, example_id) REFERENCES todo_training_examples(user_id, id) ON DELETE CASCADE
      """,
      "ALTER TABLE todo_training_feedback DROP CONSTRAINT todo_training_feedback_example_scope"
    )

    create unique_index(:todo_training_feedback, [:user_id, :dedupe_key])

    create unique_index(:todo_training_feedback, [:learning_event_id],
             where: "learning_event_id IS NOT NULL"
           )

    create index(:todo_training_feedback, [:user_id, :todo_id, :inserted_at])
    create index(:todo_training_feedback, [:user_id, :inserted_at, :id])
    create index(:todo_training_feedback, [:example_id, :inserted_at])

    create constraint(:todo_training_feedback, :todo_training_feedback_label,
             check:
               "label IN ('positive', 'negative', 'unknown', 'correction') AND actor IN ('user', 'agent') AND strength IN ('explicit', 'implicit', 'none')"
           )

    # Frozen logical records permit ciphertext rotation, but never a changed
    # digest, ownership, timestamp, association, or label. Export verifies the
    # plaintext digest. Runs may advance their operational status only.
    execute(
      """
      CREATE FUNCTION public.enforce_todo_training_record() RETURNS trigger
      LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
      DECLARE ignored text[] := ARRAY['payload'];
      BEGIN
        IF TG_OP = 'UPDATE' THEN
          IF TG_TABLE_NAME = 'todo_training_runs' THEN
            ignored := ignored || ARRAY['status', 'completed_at', 'updated_at', 'result'];
            IF OLD.status = 'pending' THEN
              ignored := ignored || ARRAY['result_hash'];
            ELSIF NEW.status IS DISTINCT FROM OLD.status OR
                  NEW.completed_at IS DISTINCT FROM OLD.completed_at THEN
              RAISE EXCEPTION 'Finished training runs are immutable' USING ERRCODE = 'check_violation';
            END IF;
          END IF;
          IF (to_jsonb(NEW) - ignored) IS DISTINCT FROM (to_jsonb(OLD) - ignored) THEN
            RAISE EXCEPTION 'Training records are immutable' USING ERRCODE = 'check_violation';
          END IF;
        END IF;
        IF TG_TABLE_NAME <> 'todo_training_runs' THEN
         IF NEW.todo_id IS NOT NULL THEN
          IF NOT EXISTS (SELECT 1 FROM public.todos WHERE id = NEW.todo_id AND user_id = NEW.user_id) THEN
            RAISE EXCEPTION 'Training todo scope mismatch' USING ERRCODE = 'check_violation';
          END IF;
         END IF;
        END IF;
        IF TG_TABLE_NAME = 'todo_training_feedback' THEN
          IF NEW.learning_event_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM public.todo_learning_events
            WHERE id = NEW.learning_event_id AND user_id = NEW.user_id AND todo_id = NEW.todo_id
          ) THEN
            RAISE EXCEPTION 'Training learning event scope mismatch' USING ERRCODE = 'check_violation';
          END IF;
        END IF;
        RETURN NEW;
      END $$
      """,
      "DROP FUNCTION public.enforce_todo_training_record()"
    )

    for table <- ~w(todo_training_runs todo_training_examples todo_training_feedback) do
      execute(
        """
        CREATE TRIGGER #{table}_immutable BEFORE INSERT OR UPDATE ON public.#{table}
        FOR EACH ROW EXECUTE FUNCTION public.enforce_todo_training_record()
        """,
        "DROP TRIGGER #{table}_immutable ON public.#{table}"
      )

      execute(
        """
        CREATE TRIGGER #{table}_privacy_fence BEFORE INSERT OR UPDATE ON public.#{table}
        FOR EACH ROW EXECUTE FUNCTION public.enforce_privacy_erasure_write_fence()
        """,
        "DROP TRIGGER #{table}_privacy_fence ON public.#{table}"
      )

      execute(
        """
        DO $$ BEGIN
          IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'maraithon_runtime') THEN
            REVOKE ALL ON TABLE public.#{table} FROM PUBLIC;
            GRANT ALL ON TABLE public.#{table} TO maraithon_migrator;
            GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.#{table} TO maraithon_runtime;
            ALTER TABLE public.#{table} OWNER TO maraithon_object_owner;
          END IF;
        END $$;
        """,
        "SELECT 1"
      )
    end
  end
end
