defmodule Maraithon.Agents do
  @moduledoc """
  Context for managing agent records in the database.
  """

  import Ecto.Query

  alias Maraithon.AgentBuilder
  alias Maraithon.AgentHarness.Manifest, as: HarnessManifest
  alias Maraithon.AgentHarness.MarkdownSkill
  alias Maraithon.AgentSubscriptions
  alias Maraithon.Connections
  alias Maraithon.Projects
  alias Maraithon.Repo
  alias Maraithon.Agents.Agent
  alias Maraithon.Agents.AgentPackage
  alias Maraithon.Agents.AgentPackageVersion
  alias Maraithon.Agents.AgentRun
  alias Maraithon.Agents.AgentRunStep

  @doc """
  List all agents.
  """
  def list_agents(opts \\ []) do
    user_id = Keyword.get(opts, :user_id)
    project_id = Keyword.get(opts, :project_id)
    preload = Keyword.get(opts, :preload, [])

    Agent
    |> maybe_filter_user(user_id)
    |> maybe_filter_project(project_id)
    |> maybe_filter_removed(Keyword.get(opts, :include_removed, false))
    |> order_by([agent], desc: agent.updated_at, desc: agent.inserted_at)
    |> Repo.all()
    |> Repo.preload(preload)
  end

  @doc """
  Get an agent by ID.
  """
  def get_agent(id, opts \\ []) do
    user_id = Keyword.get(opts, :user_id)
    preload = Keyword.get(opts, :preload, [])

    Agent
    |> maybe_filter_user(user_id)
    |> maybe_filter_removed(Keyword.get(opts, :include_removed, false))
    |> Repo.get(id)
    |> Repo.preload(preload)
  end

  @doc """
  Get an agent by ID, raising if not found.
  """
  def get_agent!(id) do
    Repo.get!(Agent, id)
  end

  def get_agent_for_user(id, user_id, opts \\ []) when is_binary(user_id) do
    preload = Keyword.get(opts, :preload, [])

    Agent
    |> where([agent], agent.id == ^id and agent.user_id == ^user_id)
    |> maybe_filter_removed(Keyword.get(opts, :include_removed, false))
    |> Repo.one()
    |> Repo.preload(preload)
  end

  @doc """
  Create a new agent record.
  """
  def create_agent(attrs \\ %{}) do
    Repo.transaction(fn ->
      with {:ok, agent} <-
             %Agent{}
             |> Agent.changeset(attrs)
             |> Repo.insert(),
           {:ok, _subscriptions} <- AgentSubscriptions.sync_for_agent(agent) do
        agent
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, agent} -> {:ok, agent}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Update an agent record.
  """
  def update_agent(%Agent{} = agent, attrs) do
    Repo.transaction(fn ->
      with {:ok, updated_agent} <-
             agent
             |> Agent.changeset(attrs)
             |> Repo.update(),
           {:ok, _subscriptions} <- AgentSubscriptions.sync_for_agent(updated_agent) do
        updated_agent
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, updated_agent} -> {:ok, updated_agent}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Delete an agent record.
  """
  def delete_agent(%Agent{} = agent) do
    Repo.delete(agent)
  end

  @doc """
  Soft-remove a user's installed agent package instance.
  """
  def remove_agent_installation(%Agent{} = agent) do
    update_agent(agent, %{
      install_status: "removed",
      status: "stopped",
      stopped_at: DateTime.utc_now(),
      removed_at: DateTime.utc_now()
    })
  end

  @doc """
  Pause an installed package agent without removing its configuration.
  """
  def pause_agent_installation(%Agent{} = agent) do
    update_agent(agent, %{
      install_status: "paused",
      status: "stopped",
      stopped_at: DateTime.utc_now()
    })
  end

  @doc """
  Resume a paused or setup-ready installed package agent.
  """
  def resume_agent_installation(%Agent{} = agent) do
    update_agent(agent, %{install_status: "enabled", removed_at: nil})
  end

  @doc """
  Upgrade an installed package agent to a package version.
  """
  def upgrade_agent_installation(%Agent{} = agent, %AgentPackageVersion{} = version) do
    if version.agent_package_id == agent.agent_package_id do
      config =
        agent.config
        |> Kernel.||(%{})
        |> Map.put("agent_package_version_id", version.id)

      update_agent(agent, %{
        behavior: version.behavior,
        agent_package_version_id: version.id,
        config: config
      })
    else
      {:error, :package_mismatch}
    end
  end

  def upgrade_agent_installation(%Agent{} = agent, version_id) when is_binary(version_id) do
    case get_agent_package_version(version_id) do
      nil -> {:error, :version_not_found}
      %AgentPackageVersion{} = version -> upgrade_agent_installation(agent, version)
    end
  end

  def upgrade_agent_installation_to_latest(%Agent{} = agent) do
    agent = Repo.preload(agent, [:agent_package])

    case agent.agent_package do
      %AgentPackage{} = package ->
        package = Repo.preload(package, [:latest_version], force: true)
        upgrade_agent_installation(agent, package.latest_version)

      _ ->
        {:error, :package_not_found}
    end
  end

  @doc """
  Create a durable execution record for one runtime cycle.
  """
  def start_agent_run(%Agent{} = agent, attrs \\ %{}) when is_map(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put(:agent_id, agent.id)
      |> Map.put(:user_id, agent.user_id)
      |> Map.put(:project_id, agent.project_id)
      |> Map.put(:behavior, agent.behavior)
      |> Map.put(:agent_package_id, agent.agent_package_id)
      |> Map.put(:agent_package_version_id, agent.agent_package_version_id)
      |> Map.put_new(:status, "running")
      |> Map.put_new(:started_at, DateTime.utc_now())

    %AgentRun{}
    |> AgentRun.changeset(attrs)
    |> Repo.insert()
  end

  def complete_agent_run(run_id, attrs \\ %{}) when is_binary(run_id) and is_map(attrs) do
    update_agent_run(run_id, Map.put_new(attrs, :status, "completed"))
  end

  def fail_agent_run(run_id, attrs \\ %{}) when is_binary(run_id) and is_map(attrs) do
    update_agent_run(run_id, Map.put_new(attrs, :status, "failed"))
  end

  def update_agent_run(run_id, attrs) when is_binary(run_id) and is_map(attrs) do
    now = DateTime.utc_now()

    attrs =
      case attrs[:status] || attrs["status"] do
        status when status in ["completed", "failed", "cancelled"] ->
          Map.put_new(attrs, :completed_at, now)

        _ ->
          attrs
      end

    case Repo.get(AgentRun, run_id) do
      nil ->
        {:error, :run_not_found}

      %AgentRun{} = run ->
        run
        |> AgentRun.changeset(attrs)
        |> Repo.update()
    end
  end

  def list_agent_runs(agent_id, opts \\ []) when is_binary(agent_id) do
    preload = Keyword.get(opts, :preload, [])
    limit = Keyword.get(opts, :limit, 50)

    AgentRun
    |> where([run], run.agent_id == ^agent_id)
    |> order_by([run], desc: run.started_at)
    |> limit(^limit)
    |> Repo.all()
    |> Repo.preload(preload)
  end

  def record_agent_run_step(run_id, agent_id, attrs)
      when is_binary(run_id) and is_binary(agent_id) and is_map(attrs) do
    sequence =
      attrs[:sequence] ||
        attrs["sequence"] ||
        next_run_step_sequence(run_id)

    attrs =
      attrs
      |> Map.new()
      |> Map.put(:agent_run_id, run_id)
      |> Map.put(:agent_id, agent_id)
      |> Map.put(:sequence, sequence)
      |> Map.put_new(:status, "requested")
      |> Map.put_new(:started_at, DateTime.utc_now())

    %AgentRunStep{}
    |> AgentRunStep.changeset(attrs)
    |> Repo.insert()
  end

  def update_agent_run_step(step_id, attrs) when is_binary(step_id) and is_map(attrs) do
    now = DateTime.utc_now()

    attrs =
      case attrs[:status] || attrs["status"] do
        status when status in ["completed", "failed"] -> Map.put_new(attrs, :completed_at, now)
        _status -> attrs
      end

    case Repo.get(AgentRunStep, step_id) do
      nil ->
        {:error, :run_step_not_found}

      %AgentRunStep{} = step ->
        step
        |> AgentRunStep.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  List marketplace packages.
  """
  def list_agent_packages(opts \\ []) do
    preload = Keyword.get(opts, :preload, [])
    status = Keyword.get(opts, :status, "published")

    AgentPackage
    |> maybe_filter_package_status(status)
    |> order_by([package], asc: package.name)
    |> Repo.all()
    |> Repo.preload(preload)
  end

  @doc """
  Return packages annotated with the current user's installation state.
  """
  def list_marketplace_packages(user_id, opts \\ [])

  def list_marketplace_packages(user_id, opts) when is_binary(user_id) do
    packages = list_agent_packages(Keyword.put_new(opts, :preload, [:latest_version]))

    installs =
      Agent
      |> where([agent], agent.user_id == ^user_id)
      |> where([agent], agent.install_status != "removed")
      |> where([agent], not is_nil(agent.agent_package_id))
      |> Repo.all()
      |> Map.new(&{&1.agent_package_id, &1})

    Enum.map(packages, fn package ->
      %{package: package, installation: Map.get(installs, package.id)}
    end)
  end

  def list_marketplace_packages(_user_id, opts) do
    list_agent_packages(Keyword.put_new(opts, :preload, [:latest_version]))
    |> Enum.map(&%{package: &1, installation: nil})
  end

  @doc """
  Returns the active installation for a package slug and user.
  """
  def get_package_installation(user_id, package_slug, opts \\ [])

  def get_package_installation(user_id, package_slug, opts)
      when is_binary(user_id) and is_binary(package_slug) do
    preload = Keyword.get(opts, :preload, [])

    Agent
    |> join(:inner, [agent], package in AgentPackage, on: package.id == agent.agent_package_id)
    |> where([agent, package], agent.user_id == ^user_id and package.slug == ^package_slug)
    |> where([agent, _package], agent.install_status != "removed")
    |> order_by([agent, _package], desc: agent.updated_at, desc: agent.inserted_at)
    |> limit(1)
    |> Repo.one()
    |> Repo.preload(preload)
  end

  def get_package_installation(_user_id, _package_slug, _opts), do: nil

  @doc """
  Get a package by slug.
  """
  def get_agent_package_by_slug(slug, opts \\ []) when is_binary(slug) do
    preload = Keyword.get(opts, :preload, [])

    AgentPackage
    |> where([package], package.slug == ^slug)
    |> Repo.one()
    |> Repo.preload(preload)
  end

  @doc """
  Create or update a package by slug.
  """
  def upsert_agent_package(attrs) when is_map(attrs) do
    slug = attrs[:slug] || attrs["slug"]

    case get_agent_package_by_slug(slug) do
      nil -> create_agent_package(attrs)
      %AgentPackage{} = package -> update_agent_package(package, attrs)
    end
  end

  def create_agent_package(attrs) when is_map(attrs) do
    %AgentPackage{}
    |> AgentPackage.changeset(attrs)
    |> Repo.insert()
  end

  def update_agent_package(%AgentPackage{} = package, attrs) when is_map(attrs) do
    package
    |> AgentPackage.changeset(attrs)
    |> Repo.update()
  end

  def publish_agent_package(%AgentPackage{} = package) do
    update_agent_package(package, %{status: "published"})
  end

  def deprecate_agent_package(%AgentPackage{} = package) do
    update_agent_package(package, %{status: "deprecated"})
  end

  def disable_agent_package(%AgentPackage{} = package) do
    update_agent_package(package, %{status: "disabled"})
  end

  def create_agent_package_version(attrs) when is_map(attrs) do
    %AgentPackageVersion{}
    |> AgentPackageVersion.changeset(attrs)
    |> Repo.insert()
  end

  def update_agent_package_version(%AgentPackageVersion{} = version, attrs) when is_map(attrs) do
    version
    |> AgentPackageVersion.changeset(attrs)
    |> Repo.update()
  end

  def get_agent_package_version(id, opts \\ []) when is_binary(id) do
    preload = Keyword.get(opts, :preload, [])

    AgentPackageVersion
    |> Repo.get(id)
    |> Repo.preload(preload)
  end

  def publish_agent_package_version(%AgentPackage{} = package, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.put_new(:agent_package_id, package.id)
      |> Map.put_new(:status, "published")

    attrs =
      if version_status(attrs) == "published" do
        Map.put_new(attrs, :published_at, DateTime.utc_now())
      else
        attrs
      end

    Repo.transaction(fn ->
      with {:ok, version} <- create_agent_package_version(attrs),
           {:ok, package} <- update_agent_package(package, %{latest_version_id: version.id}) do
        %{package | latest_version: version}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, package} -> {:ok, package}
      {:error, reason} -> {:error, reason}
    end
  end

  def publish_agent_package_version(%AgentPackageVersion{} = version) do
    published_at = version.published_at || DateTime.utc_now()

    Repo.transaction(fn ->
      with {:ok, version} <-
             update_agent_package_version(version, %{
               status: "published",
               published_at: published_at
             }),
           %AgentPackage{} = package <- Repo.get(AgentPackage, version.agent_package_id),
           {:ok, _package} <- update_agent_package(package, %{latest_version_id: version.id}) do
        version
      else
        nil -> Repo.rollback(:package_not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, version} -> {:ok, version}
      {:error, reason} -> {:error, reason}
    end
  end

  def deprecate_agent_package_version(%AgentPackageVersion{} = version) do
    update_agent_package_version(version, %{status: "deprecated"})
  end

  def disable_agent_package_version(%AgentPackageVersion{} = version) do
    update_agent_package_version(version, %{status: "disabled"})
  end

  @doc """
  Install the latest published version of a package for a user.
  """
  def install_agent_package(user_id, package_slug, opts \\ [])
      when is_binary(user_id) and is_binary(package_slug) do
    with %AgentPackage{} = package <-
           get_agent_package_by_slug(package_slug, preload: [:latest_version]),
         %AgentPackageVersion{} = version <- package.latest_version do
      attrs = installation_attrs(user_id, package, version, opts)
      create_agent(attrs)
    else
      nil -> {:error, :package_not_found}
    end
  end

  @doc """
  Installs or updates the Chief of Staff package for a user.

  Connector readiness controls the persisted install/runtime status:
  connected requirements produce an enabled, resumable agent; missing
  requirements produce a setup-required, stopped agent.
  """
  def install_chief_of_staff(user_id, opts \\ [])

  def install_chief_of_staff(user_id, opts) when is_binary(user_id) do
    project_id = Keyword.get(opts, :project_id)

    with :ok <- validate_install_project(user_id, project_id),
         {:ok, _packages} <- Maraithon.AgentMarketplace.sync_builtin_packages(),
         %AgentPackage{} = package <-
           get_agent_package_by_slug("ai_chief_of_staff", preload: [:latest_version]),
         %AgentPackageVersion{} = version <- package.latest_version do
      required_connectors = Maraithon.AgentMarketplace.required_connectors_for(package)
      readiness = Connections.connector_readiness(user_id, required_connectors)
      ready? = Enum.all?(readiness, & &1.connected?)

      install_status = if ready?, do: "enabled", else: "setup_required"
      runtime_status = if ready?, do: "running", else: "stopped"

      opts =
        opts
        |> Keyword.put(:project_id, project_id)
        |> Keyword.put(:install_status, install_status)
        |> Keyword.put(:runtime_status, runtime_status)
        |> Keyword.put_new(:delivery_policy, %{"telegram" => "enabled"})

      case get_package_installation(user_id, package.slug) do
        nil ->
          attrs = installation_attrs(user_id, package, version, opts)
          create_agent(attrs)

        %Agent{} = existing ->
          attrs =
            installation_attrs(user_id, package, version, opts)
            |> Map.take([
              :project_id,
              :config,
              :status,
              :install_status,
              :connector_grants,
              :schedule_policy,
              :delivery_policy,
              :memory_scope,
              :agent_package_id,
              :agent_package_version_id
            ])
            |> Map.put(:installed_at, existing.installed_at || DateTime.utc_now())

          update_agent(existing, attrs)
      end
    else
      nil -> {:error, :package_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def install_chief_of_staff(_user_id, _opts), do: {:error, :invalid_user}

  @doc """
  Seed or update a database package from an in-memory manifest.
  """
  def sync_agent_package_manifest(manifest) when is_map(manifest) do
    with {:ok, package_attrs, version_attrs} <- package_manifest_attrs(manifest) do
      Repo.transaction(fn ->
        with {:ok, package} <- upsert_agent_package(package_attrs),
             {:ok, package} <- upsert_latest_version(package, version_attrs) do
          package
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, package} -> {:ok, Repo.preload(package, [:latest_version], force: true)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def sync_agent_package_manifest(_manifest) do
    {:error, {:invalid_agent_manifest, [manifest: "must be a map"]}}
  end

  @doc """
  Count agents by status.
  """
  def count_by_status(status) do
    from(a in Agent, where: a.status == ^status, select: count(a.id))
    |> Repo.one()
  end

  @doc """
  List agents that should be resumed on startup.
  """
  def list_resumable_agents(opts \\ []) do
    user_id = Keyword.get(opts, :user_id)
    project_id = Keyword.get(opts, :project_id)
    preload = Keyword.get(opts, :preload, [])

    from(a in Agent, where: a.status in ["running", "degraded"])
    |> maybe_filter_user(user_id)
    |> maybe_filter_project(project_id)
    |> maybe_filter_removed(Keyword.get(opts, :include_removed, false))
    |> Repo.all()
    |> Repo.preload(preload)
  end

  @doc """
  Mark agent as running.
  """
  def mark_running(%Agent{} = agent) do
    update_agent(agent, %{status: "running", started_at: DateTime.utc_now()})
  end

  @doc """
  Mark agent as stopped.
  """
  def mark_stopped(%Agent{} = agent) do
    update_agent(agent, %{status: "stopped", stopped_at: DateTime.utc_now()})
  end

  @doc """
  Mark agent as degraded.
  """
  def mark_degraded(%Agent{} = agent) do
    update_agent(agent, %{status: "degraded"})
  end

  defp maybe_filter_user(query, nil), do: query
  defp maybe_filter_user(query, ""), do: query

  defp maybe_filter_user(query, user_id) when is_binary(user_id) do
    where(query, [agent], agent.user_id == ^user_id)
  end

  defp maybe_filter_project(query, nil), do: query
  defp maybe_filter_project(query, ""), do: query

  defp maybe_filter_project(query, project_id) when is_binary(project_id) do
    where(query, [agent], agent.project_id == ^project_id)
  end

  defp maybe_filter_removed(query, true), do: query

  defp maybe_filter_removed(query, false) do
    where(query, [agent], agent.install_status != "removed")
  end

  defp maybe_filter_package_status(query, :all), do: query
  defp maybe_filter_package_status(query, nil), do: query

  defp maybe_filter_package_status(query, status),
    do: where(query, [package], package.status == ^status)

  defp validate_install_project(_user_id, nil), do: :ok
  defp validate_install_project(_user_id, ""), do: :ok

  defp validate_install_project(user_id, project_id)
       when is_binary(user_id) and is_binary(project_id) do
    case Projects.get_project_for_user(project_id, user_id) do
      nil -> {:error, :project_not_found}
      _project -> :ok
    end
  end

  defp validate_install_project(_user_id, _project_id), do: {:error, :project_not_found}

  defp next_run_step_sequence(run_id) do
    AgentRunStep
    |> where([step], step.agent_run_id == ^run_id)
    |> select([step], max(step.sequence))
    |> Repo.one()
    |> case do
      nil -> 1
      sequence -> sequence + 1
    end
  end

  defp installation_attrs(user_id, package, version, opts) do
    config_overrides = Keyword.get(opts, :config, %{})

    config =
      version
      |> package_default_config(user_id)
      |> deep_merge(stringify_keys(config_overrides))
      |> Map.put_new("name", package.name)
      |> Map.put("agent_package_version_id", version.id)

    %{
      user_id: user_id,
      project_id: Keyword.get(opts, :project_id),
      behavior: version.behavior,
      config: config,
      status: Keyword.get(opts, :runtime_status, "stopped"),
      install_status: Keyword.get(opts, :install_status, "enabled"),
      installed_at: DateTime.utc_now(),
      agent_package_id: package.id,
      agent_package_version_id: version.id,
      connector_grants: Keyword.get(opts, :connector_grants, %{}),
      schedule_policy: Keyword.get(opts, :schedule_policy, %{}),
      delivery_policy: Keyword.get(opts, :delivery_policy, %{}),
      memory_scope: Keyword.get(opts, :memory_scope, %{})
    }
  end

  defp upsert_latest_version(package, attrs) do
    version = Map.fetch!(attrs, :version)

    existing =
      AgentPackageVersion
      |> where([package_version], package_version.agent_package_id == ^package.id)
      |> where([package_version], package_version.version == ^version)
      |> Repo.one()

    case existing do
      nil ->
        publish_agent_package_version(package, attrs)

      %AgentPackageVersion{} = existing ->
        with {:ok, updated_version} <-
               existing
               |> AgentPackageVersion.changeset(Map.put(attrs, :agent_package_id, package.id))
               |> Repo.update(),
             {:ok, updated_package} <-
               update_agent_package(package, %{latest_version_id: updated_version.id}) do
          {:ok, %{updated_package | latest_version: updated_version}}
        end
    end
  end

  defp package_default_config(%AgentPackageVersion{} = version, user_id) do
    case version.default_config do
      %{"behavior" => _behavior} = launch ->
        source_behavior = source_behavior(launch)
        launch_for_config = Map.put(launch, "behavior", source_behavior)

        case AgentBuilder.build_start_params(launch_for_config, user_id) do
          {:ok, %{"config" => config, "budget" => budget}} ->
            config
            |> Map.put("budget", budget)
            |> Map.put("source_behavior", source_behavior)
            |> Map.put("marketplace_behavior", version.behavior)

          {:ok, %{"config" => config}} ->
            config
            |> Map.put("source_behavior", source_behavior)
            |> Map.put("marketplace_behavior", version.behavior)

          {:error, _reason} ->
            version.default_config
        end

      config when is_map(config) ->
        config

      _ ->
        %{}
    end
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right

  defp source_behavior(%{"source_behavior" => behavior})
       when is_binary(behavior) and behavior != "",
       do: behavior

  defp source_behavior(%{"behavior" => behavior}) when is_binary(behavior), do: behavior
  defp source_behavior(_launch), do: "prompt_agent"

  defp package_manifest_attrs(manifest) do
    manifest = HarnessManifest.normalize(manifest)

    errors =
      required_manifest_errors(manifest, [
        :slug,
        :name,
        :behavior,
        :model,
        :intelligence
      ])
      |> Kernel.++(semantic_manifest_errors(manifest))

    if errors == [] do
      {:ok, package_attrs(manifest), version_attrs(manifest)}
    else
      {:error, {:invalid_agent_manifest, errors}}
    end
  end

  defp required_manifest_errors(manifest, required_keys) do
    Enum.flat_map(required_keys, fn key ->
      case manifest_text(manifest, key) do
        value when is_binary(value) and value != "" -> []
        _ -> [{key, "is required"}]
      end
    end)
  end

  defp semantic_manifest_errors(manifest) do
    case manifest_text(manifest, :behavior) do
      "manifest_agent" -> markdown_skill_errors(manifest)
      _behavior -> []
    end
  end

  defp markdown_skill_errors(manifest) do
    skill_paths =
      manifest
      |> HarnessManifest.get(:skill_paths)
      |> List.wrap()
      |> Enum.filter(&present_text?/1)

    cond do
      skill_paths == [] ->
        [skill_paths: "must include at least one Markdown skill path"]

      true ->
        case MarkdownSkill.load_many(skill_paths) do
          {:ok, _skills} -> []
          {:error, reason} -> [skill_paths: "could not load Markdown skills: #{inspect(reason)}"]
        end
    end
  end

  defp package_attrs(manifest) do
    %{
      slug: manifest_text(manifest, :slug),
      name: manifest_text(manifest, :name),
      summary: HarnessManifest.get(manifest, :summary),
      category: HarnessManifest.get(manifest, :category),
      source_kind: manifest_text(manifest, :source_kind, "builtin"),
      status: manifest_text(manifest, :status, "published"),
      owner_user_id: HarnessManifest.get(manifest, :owner_user_id),
      manifest: manifest
    }
  end

  defp version_attrs(manifest) do
    %{
      version: manifest_text(manifest, :version, "1.0.0"),
      changelog: HarnessManifest.get(manifest, :changelog),
      behavior: manifest_text(manifest, :behavior),
      system_prompt: HarnessManifest.get(manifest, :system_prompt),
      model: manifest_text(manifest, :model),
      intelligence: manifest_text(manifest, :intelligence),
      goals: List.wrap(HarnessManifest.get(manifest, :goals)),
      skill_paths: List.wrap(HarnessManifest.get(manifest, :skill_paths)),
      required_connectors: manifest_map(manifest, :required_connectors),
      tool_allowlist: List.wrap(HarnessManifest.get(manifest, :tool_allowlist)),
      mcp_allowlist: List.wrap(HarnessManifest.get(manifest, :mcp_allowlist)),
      default_config: manifest_map(manifest, :default_config),
      manifest: manifest,
      status: manifest_text(manifest, :version_status, "published")
    }
  end

  defp manifest_text(manifest, key, default \\ nil) do
    case HarnessManifest.get(manifest, key, default) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value ->
        value
    end
  end

  defp present_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_text?(_value), do: false

  defp manifest_map(manifest, key) do
    case HarnessManifest.get(manifest, key, %{}) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp version_status(attrs) when is_map(attrs) do
    attrs[:status] || attrs["status"]
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_keys(_), do: %{}
end
