defmodule Maraithon.Crm do
  @moduledoc """
  Context for user-scoped CRM people and their links to Maraithon data.
  """

  import Ecto.Query

  alias Maraithon.Crm.{Person, PersonLink, PersonMerge}
  alias Maraithon.Goals.GoalLink
  alias Maraithon.Repo
  alias Maraithon.Todos

  @default_people_limit 25
  @default_link_limit 25

  def list_people(user_id, opts \\ [])

  def list_people(user_id, opts) when is_binary(user_id) do
    limit = opts |> Keyword.get(:limit, @default_people_limit) |> clamp_limit(1, 500)
    page_offset = opts |> Keyword.get(:offset, 0) |> clamp_offset()
    query_text = normalize_string(Keyword.get(opts, :query))
    relationship = normalize_string(Keyword.get(opts, :relationship))
    method = normalize_string(Keyword.get(opts, :preferred_communication_method))
    frequency = normalize_string(Keyword.get(opts, :communication_frequency))
    contact_kind = normalize_string(Keyword.get(opts, :contact_kind))
    contact_value = normalize_string(Keyword.get(opts, :contact_value))
    status = normalize_string(Keyword.get(opts, :status, "active"))

    Person
    |> where([person], person.user_id == ^user_id)
    |> maybe_filter_status(status)
    |> maybe_filter_people_query(query_text)
    |> maybe_filter_text(:relationship, relationship)
    |> maybe_filter_text(:preferred_communication_method, method)
    |> maybe_filter_text(:communication_frequency, frequency)
    |> maybe_filter_contact(contact_kind, contact_value)
    |> order_people(query_text)
    |> offset(^page_offset)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_people(_user_id, _opts), do: []

  @doc """
  Ranked "who should I reconnect with" suggestions for the user, each with a
  concrete reason tied to open work, an overdue cadence, or a strong
  relationship going quiet. Delegates to
  `Maraithon.Crm.ReconnectSuggestions.suggestions/2`.
  """
  def reconnect_suggestions(user_id, opts \\ [])

  def reconnect_suggestions(user_id, opts) when is_binary(user_id) do
    Maraithon.Crm.ReconnectSuggestions.suggestions(user_id, opts)
  end

  def reconnect_suggestions(_user_id, _opts), do: []

  @doc """
  Goal-discovered people for the user, each with a goal-specific reason.

  This is separate from the general reconnect list so the People surface can
  show contacts who matter to goals even when they are not high-volume
  contacts and do not have open work.
  """
  def goal_people_opportunities(user_id, opts \\ [])

  def goal_people_opportunities(user_id, opts) when is_binary(user_id) do
    Maraithon.Crm.ReconnectSuggestions.goal_opportunities(user_id, opts)
  end

  def goal_people_opportunities(_user_id, _opts), do: []

  def people_for_resource(user_id, resource_type, resource_id, opts \\ [])

  def people_for_resource(user_id, resource_type, resource_id, opts)
      when is_binary(user_id) and is_binary(resource_type) and is_binary(resource_id) do
    limit = opts |> Keyword.get(:limit, @default_people_limit) |> clamp_limit(1, 25)

    Person
    |> join(:inner, [person], link in PersonLink,
      on:
        link.user_id == ^user_id and link.person_id == person.id and
          link.resource_type == ^resource_type and link.resource_id == ^resource_id
    )
    |> where([person, _link], person.user_id == ^user_id and person.status == "active")
    |> order_by([person, link],
      asc: link.role,
      desc: link.updated_at,
      desc: link.inserted_at,
      asc: fragment("lower(?)", person.display_name)
    )
    |> limit(^limit)
    |> Repo.all()
  end

  def people_for_resource(_user_id, _resource_type, _resource_id, _opts), do: []

  def list_family_context(user_id, opts \\ [])

  def list_family_context(user_id, opts) when is_binary(user_id) do
    limit = opts |> Keyword.get(:limit, @default_people_limit) |> clamp_limit(1, 100)
    status = normalize_string(Keyword.get(opts, :status, "active"))

    Person
    |> where([person], person.user_id == ^user_id)
    |> maybe_filter_status(status)
    |> where(
      [person],
      fragment("? ->> 'relationship_domain' = ?", person.metadata, "family") or
        fragment("? ->> 'family_member' = ?", person.metadata, "true") or
        fragment("? ->> 'family_proxy' = ?", person.metadata, "true")
    )
    |> order_people(nil)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_family_context(_user_id, _opts), do: []

  @doc """
  Substring search across the user's CRM people on `display_name`,
  `first_name`, `last_name`, `notes`, and stored contact details. Thin
  wrapper around `list_people/2` shaped to match the other context-module
  `search/3` signatures used by `Maraithon.Tools.RecallAnywhere`.
  """
  def search_people(user_id, query, opts \\ [])

  def search_people(user_id, query, opts)
      when is_binary(user_id) and is_binary(query) and is_list(opts) do
    list_people(user_id, Keyword.put(opts, :query, query))
  end

  def search_people(_user_id, _query, _opts), do: []

  def get_person_for_user(user_id, person_id, opts \\ [])

  def get_person_for_user(user_id, person_id, opts)
      when is_binary(user_id) and is_binary(person_id) do
    preload = Keyword.get(opts, :preload, [])

    Person
    |> where([person], person.user_id == ^user_id and person.id == ^person_id)
    |> Repo.one()
    |> Repo.preload(preload)
  end

  def get_person_for_user(_user_id, _person_id, _opts), do: nil

  def create_person(user_id, attrs \\ %{})

  def create_person(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    %Person{user_id: user_id}
    |> Person.changeset(apply_relationship_metric_growth(attrs, nil))
    |> Repo.insert()
    |> tap_refresh_embedding()
  end

  def create_person(_user_id, _attrs), do: {:error, :invalid_person_attrs}

  def update_person(%Person{} = person, attrs) when is_map(attrs) do
    person
    |> Person.changeset(apply_relationship_metric_growth(attrs, person))
    |> Repo.update()
    |> tap_refresh_embedding()
  end

  def update_person(_person, _attrs), do: {:error, :invalid_person_attrs}

  defp tap_refresh_embedding({:ok, %Person{} = person} = result) do
    Maraithon.Crm.PersonEmbeddings.refresh_async(person)
    result
  end

  defp tap_refresh_embedding(result), do: result

  @doc """
  Find the closest CRM person to `query` by embedding-based cosine similarity.

  Falls back gracefully (returns nil) when no embeddings are stored, or when
  embedding generation isn't available.
  """
  def semantic_find_person(user_id, query, opts \\ [])

  def semantic_find_person(user_id, query, opts)
      when is_binary(user_id) and is_binary(query) and is_list(opts) do
    threshold = Keyword.get(opts, :threshold, 0.45)

    with {:ok, vector} <- Maraithon.LLM.Embeddings.embed(query, opts) do
      do_semantic_find_person(user_id, vector, threshold)
    else
      _other -> nil
    end
  end

  def semantic_find_person(_user_id, _query, _opts), do: nil

  defp do_semantic_find_person(user_id, vector, threshold) do
    if pgvector_available?() do
      pgvector = Pgvector.new(vector)

      result =
        Repo.query!(
          """
          SELECT id, 1 - (embedding <=> $1::vector) AS similarity
          FROM crm_people
          WHERE user_id = $2 AND status = 'active' AND embedding IS NOT NULL
          ORDER BY embedding <=> $1::vector
          LIMIT 1
          """,
          [pgvector, user_id]
        )

      case result.rows do
        [[uuid_bin, similarity]] when similarity >= threshold ->
          {:ok, uuid} = Ecto.UUID.load(uuid_bin)
          get_person_for_user(user_id, uuid)

        _other ->
          nil
      end
    else
      nil
    end
  end

  defp pgvector_available? do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM information_schema.columns " <>
          "WHERE table_name = 'crm_people' AND column_name = 'embedding'"
      )

    rows != []
  rescue
    _ -> false
  end

  def upsert_person(user_id, attrs \\ %{})

  def upsert_person(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    attrs = stringify_keys(attrs)

    case person_id_from_attrs(attrs) do
      person_id when is_binary(person_id) ->
        case get_person_for_user(user_id, person_id) do
          %Person{} = person -> update_person(person, attrs)
          nil -> {:error, :person_not_found}
        end

      nil ->
        case find_existing_person(user_id, attrs) do
          %Person{} = person ->
            update_person(person, preserve_specific_display_name(person, attrs))

          nil ->
            create_person(user_id, attrs)
        end
    end
  end

  def upsert_person(_user_id, _attrs), do: {:error, :invalid_person_attrs}

  @doc """
  Look up a person for the user by a single inbound identifier or upsert a stub.

  `identifier` is a map like `%{email: "charlie@example.com"}`,
  `%{slack_id: "U123"}`, `%{phone: "+1..."}`, or `%{telegram_id: "987"}`.
  When no existing person matches, a minimal `Person` is created with the
  identifier in `contact_details` and a `display_name` derived from the
  caller-supplied option, the email local-part, or the raw identifier value.

  Used by the CRM ingestion loop to resolve participants synchronously without
  invoking the LLM.
  """
  def resolve_contact(user_id, identifier, opts \\ [])

  def resolve_contact(user_id, identifier, opts)
      when is_binary(user_id) and is_map(identifier) do
    attrs =
      identifier
      |> identifier_to_person_attrs(Keyword.get(opts, :display_name))
      |> stringify_keys()

    if attrs == %{} or person_changeset_blank?(attrs) do
      {:error, :unresolvable_contact}
    else
      case find_existing_person(user_id, attrs) do
        %Person{} = person -> {:ok, person}
        nil -> create_person(user_id, attrs)
      end
    end
  end

  def resolve_contact(_user_id, _identifier, _opts), do: {:error, :invalid_identifier}

  @doc """
  Resolve an active person by a contact value, including phone numbers that may
  be formatted differently between source data and CRM contact details.
  """
  def find_person_by_contact(user_id, contact_value, opts \\ [])

  def find_person_by_contact(user_id, contact_value, opts)
      when is_binary(user_id) and is_binary(contact_value) and is_list(opts) do
    with value when is_binary(value) <- normalize_string(contact_value) do
      kind = opts |> Keyword.get(:contact_kind) |> normalize_contact_lookup_kind()

      user_id
      |> people_for_contact_scan()
      |> Enum.find(&person_contact_matches?(&1, kind, value))
    end
  end

  def find_person_by_contact(_user_id, _contact_value, _opts), do: nil

  @doc """
  Atomically increment `interaction_count` and advance `last_interaction_at`
  forward (never backward) for the given person.

  Called from the synchronous CRM ingestion path so that "Charlie just emailed
  me" is reflected in the CRM the moment a webhook arrives, before any LLM
  pass runs.
  """
  def bump_interaction(person_id, %DateTime{} = occurred_at, source)
      when is_binary(person_id) and is_binary(source) do
    now = DateTime.utc_now()

    query =
      from(p in Person, where: p.id == ^person_id)
      |> update([p],
        inc: [interaction_count: 1],
        set: [
          last_interaction_at:
            fragment(
              "GREATEST(COALESCE(?, ?), ?)",
              p.last_interaction_at,
              ^DateTime.from_unix!(0),
              ^occurred_at
            ),
          updated_at: ^now
        ]
      )

    case Repo.update_all(query, []) do
      {1, _} -> {:ok, :bumped}
      {0, _} -> {:error, :person_not_found}
    end
  end

  def bump_interaction(_person_id, _occurred_at, _source), do: {:error, :invalid_bump}

  def delete_person(user_id, person_id)
      when is_binary(user_id) and is_binary(person_id) do
    case get_person_for_user(user_id, person_id) do
      %Person{} = person -> Repo.delete(person)
      nil -> {:error, :person_not_found}
    end
  end

  def delete_person(_user_id, _person_id), do: {:error, :person_not_found}

  def merge_people(user_id, surviving_id, merged_id, attrs \\ %{})

  def merge_people(user_id, surviving_id, merged_id, attrs)
      when is_binary(user_id) and is_binary(surviving_id) and is_binary(merged_id) and
             is_map(attrs) do
    attrs = stringify_keys(attrs)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.transaction(fn ->
        with :ok <- reject_self_merge(surviving_id, merged_id),
             %Person{} = surviving <- get_person_for_user(user_id, surviving_id),
             %Person{} = merged <- get_person_for_user(user_id, merged_id),
             :ok <- ensure_mergeable(surviving, merged),
             {:ok, surviving} <- update_surviving_person(surviving, merged, now),
             %{repointed: repointed, collapsed: collapsed} <-
               move_person_links(user_id, surviving.id, merged.id),
             %{repointed: repointed_goal_links, collapsed: collapsed_goal_links} <-
               move_goal_links(user_id, surviving.id, merged.id, now),
             {:ok, merged} <- mark_person_merged(merged, surviving, attrs, now),
             {:ok, audit} <- insert_person_merge_audit(user_id, surviving, merged, attrs, now) do
          %{
            surviving_person: surviving,
            merged_person: merged,
            audit: audit,
            repointed_link_count: repointed,
            collapsed_link_count: collapsed,
            repointed_goal_link_count: repointed_goal_links,
            collapsed_goal_link_count: collapsed_goal_links
          }
        else
          nil -> Repo.rollback(:person_not_found)
          {:error, reason} -> Repo.rollback(reason)
          reason when is_atom(reason) -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, %{surviving_person: %Person{} = person} = merge_result} ->
        Maraithon.Crm.PersonEmbeddings.refresh_async(person)
        {:ok, merge_result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def merge_people(_user_id, _surviving_id, _merged_id, _attrs),
    do: {:error, :invalid_merge_attrs}

  def list_links_for_person(user_id, person_id, opts \\ [])

  def list_links_for_person(user_id, person_id, opts)
      when is_binary(user_id) and is_binary(person_id) do
    limit = opts |> Keyword.get(:limit, @default_link_limit) |> clamp_limit(1, 100)
    resource_type = normalize_string(Keyword.get(opts, :resource_type))

    PersonLink
    |> where([link], link.user_id == ^user_id and link.person_id == ^person_id)
    |> maybe_filter_link_resource_type(resource_type)
    |> order_by([link], desc: link.updated_at, desc: link.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_links_for_person(_user_id, _person_id, _opts), do: []

  def relationship_contexts(user_id, people, opts \\ [])

  def relationship_contexts(user_id, people, opts)
      when is_binary(user_id) and is_list(people) do
    people = Enum.filter(people, &match?(%Person{}, &1))
    person_ids = people |> Enum.map(& &1.id) |> Enum.uniq()

    if person_ids == [] do
      []
    else
      link_limit = opts |> Keyword.get(:link_limit, @default_link_limit) |> clamp_limit(1, 100)
      resource_type = normalize_string(Keyword.get(opts, :resource_type))
      links_by_person = links_for_people(user_id, person_ids, link_limit, resource_type)
      todos_by_id = linked_todos_by_id(user_id, Map.values(links_by_person) |> List.flatten())

      Enum.map(people, fn %Person{} = person ->
        links = Map.get(links_by_person, person.id, [])

        todos =
          links
          |> Enum.filter(&(&1.resource_type == "todo"))
          |> Enum.map(&Map.get(todos_by_id, &1.resource_id))
          |> Enum.reject(&is_nil/1)

        %{
          person: person,
          links: links,
          todos: todos,
          open_todo_count: Enum.count(todos, &(&1.status in ["open", "snoozed"]))
        }
      end)
    end
  end

  def relationship_contexts(_user_id, _people, _opts), do: []

  def attach_resource(user_id, person_id, attrs \\ %{})

  def attach_resource(user_id, person_id, attrs)
      when is_binary(user_id) and is_binary(person_id) and is_map(attrs) do
    attrs = normalize_link_attrs(attrs)

    with %Person{} = _person <- get_person_for_user(user_id, person_id),
         {:ok, attrs} <- require_link_identity(attrs) do
      case get_existing_link(user_id, person_id, attrs) do
        %PersonLink{} = link ->
          link
          |> PersonLink.changeset(attrs)
          |> Repo.update()

        nil ->
          %PersonLink{user_id: user_id, person_id: person_id}
          |> PersonLink.changeset(attrs)
          |> Repo.insert()
      end
    else
      nil -> {:error, :person_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def attach_resource(_user_id, _person_id, _attrs), do: {:error, :invalid_person_link_attrs}

  def detach_resource(user_id, person_id, attrs \\ %{})

  def detach_resource(user_id, person_id, attrs)
      when is_binary(user_id) and is_binary(person_id) and is_map(attrs) do
    attrs = normalize_link_attrs(attrs)

    link =
      case normalize_string(Map.get(attrs, "link_id")) do
        link_id when is_binary(link_id) ->
          Repo.get_by(PersonLink, id: link_id, user_id: user_id, person_id: person_id)

        nil ->
          with {:ok, attrs} <- require_link_identity(attrs) do
            get_existing_link(user_id, person_id, attrs)
          else
            {:error, _reason} -> nil
          end
      end

    case link do
      %PersonLink{} = link -> Repo.delete(link)
      nil -> {:error, :person_link_not_found}
    end
  end

  def detach_resource(_user_id, _person_id, _attrs), do: {:error, :person_link_not_found}

  def relationship_context(user_id, attrs \\ %{})

  def relationship_context(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    attrs = stringify_keys(attrs)
    link_limit = attrs |> Map.get("link_limit", Map.get(attrs, "limit")) |> clamp_limit(1, 100)

    case resolve_person(user_id, attrs) do
      %Person{} = person ->
        links = list_links_for_person(user_id, person.id, limit: link_limit)
        todos = linked_todos(user_id, links)

        {:ok,
         %{
           person: person,
           links: links,
           todos: todos,
           open_todo_count: Enum.count(todos, &(&1.status in ["open", "snoozed"]))
         }}

      nil ->
        {:error, :person_not_found}
    end
  end

  def relationship_context(_user_id, _attrs), do: {:error, :person_not_found}

  def summarize_for_prompt(user_id, limit \\ 12)

  def summarize_for_prompt(user_id, limit) when is_binary(user_id) do
    limit = clamp_limit(limit, 1, 100)

    family_people = list_family_context(user_id, limit: limit)

    (family_people ++ list_people(user_id, limit: limit))
    |> Enum.uniq_by(& &1.id)
    |> Enum.take(limit)
    |> Enum.map(&serialize_for_prompt/1)
  end

  def summarize_for_prompt(_user_id, _limit), do: []

  def serialize_for_prompt(%Person{} = person) do
    %{
      id: person.id,
      first_name: person.first_name,
      last_name: person.last_name,
      display_name: person.display_name,
      preferred_communication_method: person.preferred_communication_method,
      relationship: person.relationship,
      communication_frequency: person.communication_frequency,
      contact_details: compact_contact_details(person.contact_details || %{}),
      notes: person.notes,
      interaction_count: person.interaction_count,
      relationship_strength: person.relationship_strength,
      affinity_score: person.affinity_score,
      last_interaction_at: person.last_interaction_at,
      metadata: person.metadata || %{}
    }
  end

  defp reject_self_merge(id, id), do: {:error, :cannot_merge_person_into_self}
  defp reject_self_merge(_surviving_id, _merged_id), do: :ok

  defp ensure_mergeable(%Person{status: "active"}, %Person{status: "active"}), do: :ok

  defp ensure_mergeable(%Person{status: "merged"}, _merged),
    do: {:error, :survivor_already_merged}

  defp ensure_mergeable(_surviving, %Person{status: "merged"}),
    do: {:error, :person_already_merged}

  defp ensure_mergeable(_surviving, _merged), do: {:error, :person_not_active}

  defp update_surviving_person(%Person{} = surviving, %Person{} = merged, %DateTime{} = now) do
    attrs =
      %{
        contact_details: merged.contact_details || %{},
        metadata: merged_survivor_metadata(surviving.metadata, merged.id, now),
        interaction_count: (surviving.interaction_count || 0) + (merged.interaction_count || 0),
        relationship_strength:
          max(surviving.relationship_strength || 0, merged.relationship_strength || 0),
        affinity_score: max(surviving.affinity_score || 0, merged.affinity_score || 0),
        last_interaction_at:
          latest_datetime(surviving.last_interaction_at, %{
            "last_interaction_at" => merged.last_interaction_at
          })
      }
      |> maybe_fill_blank(:preferred_communication_method, surviving, merged)
      |> maybe_fill_blank(:relationship, surviving, merged)
      |> maybe_fill_blank(:communication_frequency, surviving, merged)
      |> maybe_fill_blank(:notes, surviving, merged)

    surviving
    |> Person.changeset(attrs)
    |> Repo.update()
  end

  defp maybe_fill_blank(attrs, field, surviving, merged) do
    if blank?(Map.get(surviving, field)) and not blank?(Map.get(merged, field)) do
      Map.put(attrs, field, Map.get(merged, field))
    else
      attrs
    end
  end

  defp merged_survivor_metadata(metadata, merged_id, %DateTime{} = now) do
    metadata = metadata || %{}

    merged_ids =
      metadata
      |> Map.get("merged_person_ids", [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> then(&[merged_id | &1])
      |> Enum.uniq()

    metadata
    |> Map.put("merged_person_ids", merged_ids)
    |> Map.put("last_person_merge_at", DateTime.to_iso8601(now))
  end

  defp move_person_links(user_id, surviving_id, merged_id) do
    PersonLink
    |> where([link], link.user_id == ^user_id and link.person_id == ^merged_id)
    |> Repo.all()
    |> Enum.reduce(%{repointed: 0, collapsed: 0}, fn link, counts ->
      case get_existing_link(user_id, surviving_id, %{
             "resource_type" => link.resource_type,
             "resource_id" => link.resource_id
           }) do
        %PersonLink{} = existing ->
          {:ok, _existing} = merge_duplicate_link(existing, link)
          {:ok, _deleted} = Repo.delete(link)
          %{counts | collapsed: counts.collapsed + 1}

        nil ->
          {:ok, _link} =
            link
            |> Ecto.Changeset.change(person_id: surviving_id)
            |> Repo.update()

          %{counts | repointed: counts.repointed + 1}
      end
    end)
  end

  defp move_goal_links(user_id, surviving_id, merged_id, %DateTime{} = now) do
    GoalLink
    |> where(
      [link],
      link.user_id == ^user_id and link.resource_type == "person" and
        link.resource_id == ^merged_id
    )
    |> Repo.all()
    |> Enum.reduce(%{repointed: 0, collapsed: 0}, fn link, counts ->
      case existing_goal_link(user_id, surviving_id, link) do
        %GoalLink{} = existing ->
          {:ok, _existing} = merge_duplicate_goal_link(existing, link, merged_id, now)
          {:ok, _deleted} = Repo.delete(link)
          %{counts | collapsed: counts.collapsed + 1}

        nil ->
          {:ok, _link} =
            link
            |> Ecto.Changeset.change(
              resource_id: surviving_id,
              metadata: repointed_goal_link_metadata(link.metadata, merged_id, now)
            )
            |> Repo.update()

          %{counts | repointed: counts.repointed + 1}
      end
    end)
  end

  defp existing_goal_link(user_id, surviving_id, %GoalLink{} = link) do
    Repo.get_by(GoalLink,
      user_id: user_id,
      goal_id: link.goal_id,
      resource_type: "person",
      resource_id: surviving_id,
      relationship: link.relationship
    )
  end

  defp merge_duplicate_goal_link(
         %GoalLink{} = existing,
         %GoalLink{} = duplicate,
         merged_id,
         %DateTime{} = now
       ) do
    attrs = %{
      confidence: max(existing.confidence || 0.0, duplicate.confidence || 0.0),
      metadata:
        existing.metadata
        |> merge_maps(duplicate.metadata)
        |> append_metadata_id("collapsed_goal_link_ids", duplicate.id)
        |> append_metadata_id("merged_from_person_ids", merged_id)
        |> Map.put("last_collapsed_goal_link_at", DateTime.to_iso8601(now))
    }

    existing
    |> Ecto.Changeset.change(attrs)
    |> Repo.update()
  end

  defp repointed_goal_link_metadata(metadata, merged_id, %DateTime{} = now) do
    metadata
    |> merge_maps(%{})
    |> append_metadata_id("merged_from_person_ids", merged_id)
    |> Map.put("repointed_goal_link_at", DateTime.to_iso8601(now))
  end

  defp append_metadata_id(metadata, key, value) when is_binary(value) do
    existing =
      metadata
      |> Map.get(key, [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)

    Map.put(metadata, key, Enum.uniq([value | existing]))
  end

  defp append_metadata_id(metadata, _key, _value), do: metadata

  defp merge_duplicate_link(%PersonLink{} = existing, %PersonLink{} = duplicate) do
    attrs = %{
      "resource_source" => first_present(existing.resource_source, duplicate.resource_source),
      "role" => first_present(existing.role, duplicate.role),
      "source_system" => first_present(existing.source_system, duplicate.source_system),
      "source_account" => first_present(existing.source_account, duplicate.source_account),
      "source_ref" => first_present(existing.source_ref, duplicate.source_ref),
      "title" => first_present(existing.title, duplicate.title),
      "summary" => first_present(existing.summary, duplicate.summary),
      "relationship_note" =>
        combine_text(existing.relationship_note, duplicate.relationship_note),
      "evidence_quote" => first_present(existing.evidence_quote, duplicate.evidence_quote),
      "model_rationale" => first_present(existing.model_rationale, duplicate.model_rationale),
      "confidence" => max(existing.confidence || 0.0, duplicate.confidence || 0.0),
      "metadata" =>
        existing.metadata
        |> merge_maps(duplicate.metadata)
        |> Map.put("collapsed_person_link_ids", [duplicate.id])
    }

    existing
    |> PersonLink.changeset(attrs)
    |> Repo.update()
  end

  defp mark_person_merged(%Person{} = merged, %Person{} = surviving, attrs, %DateTime{} = now) do
    metadata =
      merged.metadata
      |> merge_maps(%{
        "merged_into_id" => surviving.id,
        "merge_evidence" => normalize_string(Map.get(attrs, "evidence")),
        "merge_model_rationale" => normalize_string(Map.get(attrs, "model_rationale"))
      })

    merged
    |> Person.changeset(%{
      status: "merged",
      merged_into_id: surviving.id,
      merged_at: now,
      metadata: metadata
    })
    |> Repo.update()
  end

  defp insert_person_merge_audit(user_id, surviving, merged, attrs, %DateTime{} = now) do
    %PersonMerge{}
    |> PersonMerge.changeset(%{
      user_id: user_id,
      surviving_person_id: surviving.id,
      merged_person_id: merged.id,
      evidence: normalize_string(Map.get(attrs, "evidence")),
      model_rationale:
        normalize_string(Map.get(attrs, "model_rationale") || Map.get(attrs, "rationale")),
      performed_by: normalize_string(Map.get(attrs, "performed_by", "model")),
      metadata: read_map(Map.get(attrs, "metadata")),
      performed_at: now
    })
    |> Repo.insert()
  end

  defp apply_relationship_metric_growth(attrs, person) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    existing_count = existing_integer(person, :interaction_count)
    existing_strength = existing_integer(person, :relationship_strength)
    existing_affinity = existing_integer(person, :affinity_score)
    existing_last_seen = person && person.last_interaction_at

    attrs
    |> maybe_put_metric(
      "interaction_count",
      grow_count(existing_count, attrs, ["interaction_count_delta", "interaction_delta"])
    )
    |> maybe_put_metric(
      "relationship_strength",
      grow_score(existing_strength, attrs, "relationship_strength", [
        "relationship_strength_delta",
        "strength_delta"
      ])
    )
    |> maybe_put_metric(
      "affinity_score",
      grow_score(existing_affinity, attrs, "affinity_score", ["affinity_delta"])
    )
    |> maybe_put_datetime("last_interaction_at", latest_datetime(existing_last_seen, attrs))
    |> Map.drop([
      "interaction_count_delta",
      "interaction_delta",
      "relationship_strength_delta",
      "strength_delta",
      "affinity_delta",
      "last_seen_at",
      "last_contacted_at"
    ])
  end

  defp apply_relationship_metric_growth(attrs, _person), do: attrs

  defp preserve_specific_display_name(%Person{} = person, attrs) when is_map(attrs) do
    incoming_display_name = normalize_display_name(attrs)

    if specific_display_name?(person.display_name) and
         single_token_display_name?(incoming_display_name) do
      Map.drop(attrs, [
        "display_name",
        "displayName",
        "first_name",
        "firstName",
        "last_name",
        "lastName"
      ])
    else
      attrs
    end
  end

  defp preserve_specific_display_name(_person, attrs), do: attrs

  defp grow_count(existing, attrs, delta_keys) do
    explicit = read_integer_attr(attrs, "interaction_count")
    delta = read_first_integer_attr(attrs, delta_keys)

    cond do
      is_integer(explicit) or is_integer(delta) ->
        [existing, explicit, existing + max(delta || 0, 0)]
        |> Enum.reject(&is_nil/1)
        |> Enum.max()

      true ->
        nil
    end
  end

  defp grow_score(existing, attrs, explicit_key, delta_keys) do
    explicit = read_integer_attr(attrs, explicit_key)
    delta = read_first_integer_attr(attrs, delta_keys)

    cond do
      is_integer(explicit) or is_integer(delta) ->
        [existing, explicit, existing + max(delta || 0, 0)]
        |> Enum.reject(&is_nil/1)
        |> Enum.max()
        |> clamp_integer(0, 100)

      true ->
        nil
    end
  end

  defp latest_datetime(existing, attrs) do
    incoming =
      read_datetime_attr(attrs, "last_interaction_at") ||
        read_datetime_attr(attrs, "last_seen_at") ||
        read_datetime_attr(attrs, "last_contacted_at")

    case {existing, incoming} do
      {%DateTime{} = existing, %DateTime{} = incoming} ->
        if DateTime.compare(incoming, existing) == :gt, do: incoming, else: existing

      {nil, %DateTime{} = incoming} ->
        incoming

      {%DateTime{} = existing, nil} ->
        existing

      _ ->
        nil
    end
  end

  defp maybe_put_metric(attrs, _key, nil), do: attrs
  defp maybe_put_metric(attrs, key, value), do: Map.put(attrs, key, value)

  defp maybe_put_datetime(attrs, _key, nil), do: attrs
  defp maybe_put_datetime(attrs, key, %DateTime{} = value), do: Map.put(attrs, key, value)

  defp existing_integer(%Person{} = person, field) do
    person
    |> Map.get(field)
    |> case do
      value when is_integer(value) -> value
      _ -> 0
    end
  end

  defp existing_integer(_person, _field), do: 0

  defp read_first_integer_attr(attrs, keys) do
    Enum.find_value(keys, &read_integer_attr(attrs, &1))
  end

  defp read_integer_attr(attrs, key) when is_map(attrs) do
    case Map.get(attrs, key) do
      value when is_integer(value) ->
        value

      value when is_float(value) ->
        round(value)

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp read_datetime_attr(attrs, key) when is_map(attrs) do
    case Map.get(attrs, key) do
      %DateTime{} = datetime ->
        datetime

      value when is_binary(value) ->
        case DateTime.from_iso8601(String.trim(value)) do
          {:ok, datetime, _offset} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp clamp_integer(value, min_value, max_value) when is_integer(value) do
    value |> max(min_value) |> min(max_value)
  end

  defp resolve_person(user_id, attrs) do
    case person_id_from_attrs(attrs) do
      person_id when is_binary(person_id) ->
        get_person_for_user(user_id, person_id)

      nil ->
        contact_kind = normalize_string(Map.get(attrs, "contact_kind"))
        contact_value = normalize_string(Map.get(attrs, "contact_value"))
        query_text = normalize_string(Map.get(attrs, "query"))

        cond do
          is_binary(contact_value) ->
            list_people(user_id,
              contact_kind: contact_kind,
              contact_value: contact_value,
              limit: 1
            )
            |> List.first()

          is_binary(query_text) ->
            list_people(user_id, query: query_text, limit: 1)
            |> List.first()

          true ->
            nil
        end
    end
  end

  defp find_existing_person(user_id, attrs) do
    identifiers = contact_identifiers(attrs)
    display_name = normalize_display_name(attrs)

    contact_match =
      Enum.find_value(identifiers, fn value ->
        find_person_by_contact(user_id, value)
      end)

    contact_match || find_existing_person_by_name(user_id, display_name, identifiers)
  end

  defp find_existing_person_by_name(_user_id, nil, _identifiers), do: nil

  defp find_existing_person_by_name(user_id, display_name, identifiers) do
    cond do
      identifiers == [] ->
        exact_name_match(user_id, display_name) ||
          fuzzy_find_person(user_id, display_name) ||
          semantic_find_person(user_id, display_name)

      single_token_display_name?(display_name) ->
        unique_specific_first_name_match(user_id, display_name)

      specific_display_name?(display_name) ->
        exact_name_match(user_id, display_name)

      true ->
        nil
    end
  end

  defp exact_name_match(user_id, display_name) do
    Person
    |> where([person], person.user_id == ^user_id)
    |> where([person], person.status == "active")
    |> where(
      [person],
      fragment("lower(?)", person.display_name) == ^String.downcase(display_name)
    )
    |> order_by([person],
      desc: person.communication_score,
      desc: person.relationship_strength,
      desc: person.affinity_score,
      desc: person.updated_at
    )
    |> limit(1)
    |> Repo.one()
  end

  defp unique_specific_first_name_match(user_id, display_name) do
    token = normalized_name_tokens(display_name) |> List.first()

    if is_binary(token) do
      matches =
        Person
        |> where([person], person.user_id == ^user_id and person.status == "active")
        |> where(
          [person],
          fragment("lower(coalesce(?, ''))", person.first_name) == ^token or
            fragment("lower(split_part(coalesce(?, ''), ' ', 1))", person.display_name) == ^token
        )
        |> order_by([person],
          desc: person.communication_score,
          desc: person.relationship_strength,
          desc: person.affinity_score,
          desc: person.updated_at
        )
        |> limit(3)
        |> Repo.all()
        |> Enum.filter(&specific_display_name?(&1.display_name))

      case matches do
        [person] -> person
        _other -> nil
      end
    end
  end

  defp fuzzy_find_person(user_id, query_text) when is_binary(query_text) do
    Person
    |> where([person], person.user_id == ^user_id)
    |> where([person], person.status == "active")
    |> where(
      [person],
      fragment(
        "similarity(coalesce(?, '') || ' ' || coalesce(?, '') || ' ' || coalesce(?, ''), ?) > 0.3",
        person.display_name,
        person.first_name,
        person.last_name,
        ^query_text
      )
    )
    |> order_by(
      [person],
      desc:
        fragment(
          "similarity(coalesce(?, '') || ' ' || coalesce(?, '') || ' ' || coalesce(?, ''), ?)",
          person.display_name,
          person.first_name,
          person.last_name,
          ^query_text
        ),
      desc: person.relationship_strength,
      desc: person.affinity_score
    )
    |> limit(1)
    |> Repo.one()
  end

  defp fuzzy_find_person(_user_id, _query_text), do: nil

  defp contact_identifiers(attrs) do
    contact_details =
      %Person{}
      |> Person.changeset(
        Map.take(
          attrs,
          ~w(contact_details contacts email emails phone phone_number phones slack_id slack_ids telegram_id telegram_ids)
        )
      )
      |> Ecto.Changeset.get_change(:contact_details, %{})

    contact_details
    |> Map.take(~w(emails phones slack_ids telegram_ids))
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_display_name(attrs) do
    %Person{}
    |> Person.changeset(attrs)
    |> Ecto.Changeset.get_change(:display_name)
    |> normalize_string()
  end

  defp specific_display_name?(value) when is_binary(value) do
    normalized_name_tokens(value)
    |> length()
    |> Kernel.>=(2)
  end

  defp specific_display_name?(_value), do: false

  defp single_token_display_name?(value) when is_binary(value) do
    normalized_name_tokens(value)
    |> length()
    |> Kernel.==(1)
  end

  defp single_token_display_name?(_value), do: false

  defp normalized_name_tokens(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}@.]+/u, " ")
    |> String.split(" ", trim: true)
    |> Enum.reject(&String.contains?(&1, "@"))
  end

  defp normalized_name_tokens(_value), do: []

  defp linked_todos(user_id, links) do
    todo_ids =
      links
      |> Enum.filter(&(&1.resource_type == "todo"))
      |> Enum.map(& &1.resource_id)
      |> Enum.uniq()

    Todos.list_by_ids(user_id, todo_ids)
  end

  defp linked_todos_by_id(user_id, links) do
    links
    |> Enum.filter(&(&1.resource_type == "todo"))
    |> Enum.map(& &1.resource_id)
    |> Enum.uniq()
    |> then(&Todos.list_by_ids(user_id, &1))
    |> Map.new(&{&1.id, &1})
  end

  defp links_for_people(user_id, person_ids, link_limit, resource_type) do
    PersonLink
    |> where([link], link.user_id == ^user_id and link.person_id in ^person_ids)
    |> maybe_filter_link_resource_type(resource_type)
    |> order_by([link], asc: link.person_id, desc: link.updated_at, desc: link.inserted_at)
    |> Repo.all()
    |> Enum.group_by(& &1.person_id)
    |> Map.new(fn {person_id, links} -> {person_id, Enum.take(links, link_limit)} end)
  end

  defp get_existing_link(user_id, person_id, attrs) do
    Repo.get_by(PersonLink,
      user_id: user_id,
      person_id: person_id,
      resource_type: Map.get(attrs, "resource_type"),
      resource_id: Map.get(attrs, "resource_id")
    )
  end

  defp require_link_identity(attrs) do
    resource_type = normalize_string(Map.get(attrs, "resource_type"))
    resource_id = normalize_string(Map.get(attrs, "resource_id"))

    cond do
      is_nil(resource_type) ->
        {:error, :missing_resource_type}

      is_nil(resource_id) ->
        {:error, :missing_resource_id}

      true ->
        {:ok, Map.merge(attrs, %{"resource_type" => resource_type, "resource_id" => resource_id})}
    end
  end

  defp normalize_link_attrs(attrs) do
    attrs
    |> stringify_keys()
    |> case do
      %{"todo_id" => todo_id} = attrs when is_binary(todo_id) ->
        attrs
        |> Map.put_new("resource_type", "todo")
        |> Map.put_new("resource_id", String.trim(todo_id))

      attrs ->
        attrs
    end
  end

  defp person_id_from_attrs(attrs) do
    normalize_string(Map.get(attrs, "person_id") || Map.get(attrs, "id"))
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, "all"), do: query
  defp maybe_filter_status(query, status), do: where(query, [person], person.status == ^status)

  defp maybe_filter_people_query(query, nil), do: query

  defp maybe_filter_people_query(query, query_text) do
    pattern = "%#{query_text}%"

    where(
      query,
      [person],
      ilike(person.first_name, ^pattern) or ilike(person.last_name, ^pattern) or
        ilike(person.display_name, ^pattern) or ilike(person.relationship, ^pattern) or
        ilike(person.notes, ^pattern) or
        fragment("?::text ILIKE ?", person.contact_details, ^pattern) or
        fragment(
          "similarity(coalesce(?, '') || ' ' || coalesce(?, '') || ' ' || coalesce(?, ''), ?) > 0.3",
          person.display_name,
          person.first_name,
          person.last_name,
          ^query_text
        )
    )
  end

  defp order_people(query, nil) do
    order_by(
      query,
      [person],
      desc: person.communication_score,
      desc: person.relationship_strength,
      desc: person.affinity_score,
      desc_nulls_last: person.last_interaction_at,
      desc: person.updated_at,
      asc: fragment("lower(?)", person.display_name)
    )
  end

  defp order_people(query, query_text) do
    order_by(
      query,
      [person],
      desc:
        fragment(
          "similarity(coalesce(?, '') || ' ' || coalesce(?, '') || ' ' || coalesce(?, ''), ?)",
          person.display_name,
          person.first_name,
          person.last_name,
          ^query_text
        ),
      desc: person.communication_score,
      desc: person.relationship_strength,
      desc: person.affinity_score,
      desc_nulls_last: person.last_interaction_at,
      desc: person.updated_at,
      asc: fragment("lower(?)", person.display_name)
    )
  end

  defp maybe_filter_text(query, _field, nil), do: query

  defp maybe_filter_text(query, field, value) do
    where(query, [person], fragment("lower(?)", field(person, ^field)) == ^String.downcase(value))
  end

  defp maybe_filter_contact(query, _kind, nil), do: query

  defp maybe_filter_contact(query, nil, contact_value) do
    pattern = "%#{contact_value}%"
    where(query, [person], fragment("?::text ILIKE ?", person.contact_details, ^pattern))
  end

  defp maybe_filter_contact(query, kind, contact_value) do
    pattern = "%#{contact_value}%"

    where(
      query,
      [person],
      fragment(
        "(? -> ?)::text ILIKE ?",
        person.contact_details,
        ^normalize_contact_kind(kind),
        ^pattern
      ) or
        fragment("?::text ILIKE ?", person.contact_details, ^pattern)
    )
  end

  defp maybe_filter_link_resource_type(query, nil), do: query

  defp maybe_filter_link_resource_type(query, resource_type) do
    where(query, [link], link.resource_type == ^resource_type)
  end

  defp normalize_contact_kind("email"), do: "emails"
  defp normalize_contact_kind("phone"), do: "phones"
  defp normalize_contact_kind("phone_number"), do: "phones"
  defp normalize_contact_kind("slack"), do: "slack_ids"
  defp normalize_contact_kind("slack_id"), do: "slack_ids"
  defp normalize_contact_kind("telegram"), do: "telegram_ids"
  defp normalize_contact_kind("telegram_id"), do: "telegram_ids"
  defp normalize_contact_kind(kind), do: kind

  defp normalize_contact_lookup_kind(nil), do: nil

  defp normalize_contact_lookup_kind(kind) when is_atom(kind) do
    kind
    |> Atom.to_string()
    |> normalize_contact_lookup_kind()
  end

  defp normalize_contact_lookup_kind(kind) when is_binary(kind) do
    kind
    |> normalize_string()
    |> normalize_contact_kind()
  end

  defp normalize_contact_lookup_kind(_kind), do: nil

  defp people_for_contact_scan(user_id) do
    Person
    |> where([person], person.user_id == ^user_id and person.status == "active")
    |> order_people(nil)
    |> Repo.all()
  end

  defp person_contact_matches?(%Person{contact_details: contact_details}, kind, value)
       when is_map(contact_details) do
    kind
    |> contact_lookup_keys()
    |> Enum.any?(fn key ->
      contact_details
      |> Map.get(key)
      |> List.wrap()
      |> Enum.any?(&contact_value_matches?(key, &1, value))
    end)
  end

  defp person_contact_matches?(_person, _kind, _value), do: false

  defp contact_lookup_keys(nil), do: ~w(emails phones slack_ids telegram_ids)
  defp contact_lookup_keys("emails"), do: ["emails"]
  defp contact_lookup_keys("phones"), do: ["phones"]
  defp contact_lookup_keys("slack_ids"), do: ["slack_ids"]
  defp contact_lookup_keys("telegram_ids"), do: ["telegram_ids"]
  defp contact_lookup_keys(kind) when is_binary(kind), do: [kind]
  defp contact_lookup_keys(_kind), do: []

  defp contact_value_matches?("phones", stored, value) when is_binary(stored) do
    stored_digits = phone_digits(stored)
    value_digits = phone_digits(value)

    cond do
      stored_digits == "" or value_digits == "" ->
        text_contact_matches?(stored, value)

      stored_digits == value_digits ->
        true

      byte_size(stored_digits) >= 10 and byte_size(value_digits) >= 10 ->
        last_digits(stored_digits, 10) == last_digits(value_digits, 10)

      min(byte_size(stored_digits), byte_size(value_digits)) >= 7 ->
        String.ends_with?(stored_digits, value_digits) or
          String.ends_with?(value_digits, stored_digits)

      true ->
        false
    end
  end

  defp contact_value_matches?(_kind, stored, value) when is_binary(stored),
    do: text_contact_matches?(stored, value)

  defp contact_value_matches?(_kind, _stored, _value), do: false

  defp text_contact_matches?(stored, value) when is_binary(stored) and is_binary(value) do
    stored = stored |> String.trim() |> String.downcase()
    value = value |> String.trim() |> String.downcase()

    stored != "" and value != "" and
      (stored == value or String.contains?(stored, value) or String.contains?(value, stored))
  end

  defp phone_digits(value) when is_binary(value) do
    for <<char <- value>>, char >= ?0 and char <= ?9, into: "", do: <<char>>
  end

  defp phone_digits(_value), do: ""

  defp last_digits(value, count) when is_binary(value) and byte_size(value) > count do
    binary_part(value, byte_size(value) - count, count)
  end

  defp last_digits(value, _count), do: value

  defp compact_contact_details(contact_details) when is_map(contact_details) do
    Map.take(contact_details, ~w(emails phones slack_ids telegram_ids))
  end

  defp compact_contact_details(_contact_details), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp blank?(value), do: normalize_string(value) == nil

  defp first_present(left, right) do
    normalize_string(left) || normalize_string(right)
  end

  defp combine_text(left, right) do
    [normalize_string(left), normalize_string(right)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join("\n\n")
    |> normalize_string()
  end

  defp merge_maps(left, right) do
    Map.merge(read_map(left), read_map(right), fn _key, left_value, right_value ->
      cond do
        is_map(left_value) and is_map(right_value) -> merge_maps(left_value, right_value)
        is_list(left_value) and is_list(right_value) -> Enum.uniq(left_value ++ right_value)
        is_nil(right_value) -> left_value
        true -> right_value
      end
    end)
  end

  defp read_map(value) when is_map(value), do: value
  defp read_map(_value), do: %{}

  defp clamp_limit(value, min_value, max_value) when is_integer(value) do
    value |> max(min_value) |> min(max_value)
  end

  defp clamp_limit(value, min_value, max_value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> clamp_limit(parsed, min_value, max_value)
      _ -> min_value
    end
  end

  defp clamp_limit(_value, min_value, _max_value), do: min_value

  defp clamp_offset(value) when is_integer(value), do: max(value, 0)

  defp clamp_offset(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> clamp_offset(parsed)
      _ -> 0
    end
  end

  defp clamp_offset(_value), do: 0

  defp identifier_to_person_attrs(identifier, override_display_name) do
    {kind, value} = pick_identifier(identifier)
    trimmed = trim_identifier(value)

    case {kind, trimmed} do
      {nil, _} ->
        %{}

      {_, nil} ->
        %{}

      {kind, value} ->
        contact_details = %{normalize_contact_kind(to_string(kind)) => [value]}

        %{
          "contact_details" => contact_details,
          "display_name" => infer_display_name(override_display_name, kind, value)
        }
    end
  end

  defp pick_identifier(identifier) when is_map(identifier) do
    candidates = ~w(email slack_id phone phone_number telegram_id)a

    Enum.reduce_while(candidates, {nil, nil}, fn key, _acc ->
      case Map.get(identifier, key) || Map.get(identifier, to_string(key)) do
        nil -> {:cont, {nil, nil}}
        "" -> {:cont, {nil, nil}}
        value -> {:halt, {key, value}}
      end
    end)
  end

  defp trim_identifier(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      v -> v
    end
  end

  defp trim_identifier(_), do: nil

  defp infer_display_name(override, _kind, _value)
       when is_binary(override) and override != "",
       do: override

  defp infer_display_name(_override, :email, value) do
    case String.split(value, "@", parts: 2) do
      [local, _domain] when local != "" ->
        local
        |> String.replace(~r/[._]+/, " ")
        |> String.split(" ", trim: true)
        |> Enum.map_join(" ", &String.capitalize/1)

      _ ->
        value
    end
  end

  defp infer_display_name(_override, _kind, value) when is_binary(value), do: value
  defp infer_display_name(_override, _kind, _value), do: nil

  defp person_changeset_blank?(attrs) do
    case normalize_display_name(attrs) do
      nil -> contact_identifiers(attrs) == []
      _ -> false
    end
  end
end
