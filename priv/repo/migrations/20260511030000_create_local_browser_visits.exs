defmodule Maraithon.Repo.Migrations.CreateLocalBrowserVisits do
  use Ecto.Migration

  # Conservative privacy deny-list applied at ingest (see
  # Maraithon.LocalBrowserHistory.ingest_batch/3). Hosts matching any of
  # these regexes are skipped on insert and titles for those rows are
  # redacted client-side / context-side. Listed here so the policy is
  # easy to revisit alongside the schema.
  #
  # (?i)(google|duckduckgo|bing)\.com.*search   - search-engine queries
  # .*bank.*                                    - any banking subdomain
  # .*\.paypal\.com.*                           - paypal flows
  # .*medical.*                                 - medical portals
  # .*health.*                                  - health portals
  # .*adult.*                                   - adult content
  # .*porn.*                                    - adult content
  def change do
    create table(:local_browser_visits, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, :string, null: false
      add :device_id, :uuid, null: false
      add :source, :string, null: false, default: "browser_history"
      add :browser, :string, null: false
      add :guid, :string
      add :local_id, :string
      add :url, :text, null: false
      add :title, :binary
      add :host, :string
      add :visit_count, :integer, null: false, default: 1
      add :last_visited_at, :utc_datetime_usec
      add :is_typed_url, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:local_browser_visits, [:user_id, :device_id, :source, :guid],
             name: :local_browser_visits_user_device_source_guid_index
           )

    create index(:local_browser_visits, [:user_id, :last_visited_at])
    create index(:local_browser_visits, [:user_id, :host, :last_visited_at])
    create index(:local_browser_visits, [:device_id])
  end
end
