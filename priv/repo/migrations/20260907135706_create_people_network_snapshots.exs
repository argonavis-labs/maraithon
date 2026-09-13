defmodule Maraithon.Repo.Migrations.CreatePeopleNetworkSnapshots do
  use Ecto.Migration

  def change do
    create table(:people_network_generations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :as_of, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
      add :invalidated_at, :utc_datetime_usec
      add :summary, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:people_network_generations, [:user_id, :inserted_at])

    create table(:people_network_profiles, primary_key: false) do
      add :generation_id,
          references(:people_network_generations, type: :binary_id, on_delete: :delete_all),
          primary_key: true

      add :window_days, :integer, primary_key: true
      add :node_id, :string, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :display_name, :string, null: false
      add :rank, :float, null: false, default: 0
      add :profile, :map, null: false, default: %{}
    end

    create index(:people_network_profiles, [:user_id, :generation_id, :window_days, :rank])

    create table(:people_network_snapshots, primary_key: false) do
      add :user_id, references(:users, type: :string, on_delete: :delete_all), primary_key: true

      add :generation_id,
          references(:people_network_generations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :refreshed_at, :utc_datetime_usec, null: false
    end

    execute(
      """
      DO $$ BEGIN
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'maraithon_runtime') THEN
          GRANT SELECT, INSERT, UPDATE, DELETE ON
            public.people_network_generations, public.people_network_profiles,
            public.people_network_snapshots TO maraithon_runtime;
        END IF;
      END $$;
      """,
      "SELECT 1"
    )

    # Source deletion must also forget cached titles, identities and evidence,
    # including generations currently being built. Statement triggers keep
    # large source purges to one projection deletion per user.
    execute(
      """
      CREATE FUNCTION public.people_network_forget_sources() RETURNS trigger
      LANGUAGE plpgsql AS $$ BEGIN
        DELETE FROM public.people_network_generations
        WHERE user_id IN (SELECT DISTINCT user_id FROM deleted_people_sources);
        RETURN NULL;
      END $$;
      """,
      "DROP FUNCTION public.people_network_forget_sources()"
    )

    for table <- ~w(local_messages local_calendar_events local_contacts crm_observations) do
      execute(
        """
        CREATE TRIGGER people_network_forget_sources
        AFTER DELETE ON public.#{table}
        REFERENCING OLD TABLE AS deleted_people_sources
        FOR EACH STATEMENT EXECUTE FUNCTION public.people_network_forget_sources();
        """,
        "DROP TRIGGER people_network_forget_sources ON public.#{table}"
      )
    end

    execute(
      """
      CREATE FUNCTION public.people_network_identity_changed() RETURNS trigger
      LANGUAGE plpgsql AS $$ BEGIN
        UPDATE public.people_network_generations SET invalidated_at = clock_timestamp()
        WHERE user_id = OLD.user_id AND invalidated_at IS NULL;
        RETURN NULL;
      END $$;
      """,
      "DROP FUNCTION public.people_network_identity_changed()"
    )

    execute(
      """
      CREATE TRIGGER people_network_identity_changed
      AFTER UPDATE OF display_name, contact_details, status, merged_into_id OR DELETE ON public.crm_people
      FOR EACH ROW EXECUTE FUNCTION public.people_network_identity_changed();
      """,
      "DROP TRIGGER people_network_identity_changed ON public.crm_people"
    )
  end
end
