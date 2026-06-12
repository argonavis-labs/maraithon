defmodule Mix.Tasks.Maraithon.SeedReviewer do
  @shortdoc "Seed the App Store reviewer's demo account with representative data"

  @moduledoc """
  Seeds the App Store review demo account so Apple's reviewer lands in a
  populated account (Today / Work / People / Chat) instead of an empty shell.

      mix maraithon.seed_reviewer

  The reviewer email defaults to `APP_REVIEW_BYPASS_EMAIL`, falling back to
  `reviewer@maraithon.com`. Run once after deploy — NOT on every boot.

  Idempotent: every seeded row carries a stable `reviewer-seed-` marker
  (dedupe_key for todos/briefs, `metadata["seed_id"]` for people/projects,
  client_thread_id for chat), so re-running updates in place instead of
  duplicating.
  """

  use Mix.Task

  alias Maraithon.Accounts
  alias Maraithon.Briefs
  alias Maraithon.Crm
  alias Maraithon.Crm.Person
  alias Maraithon.Projects
  alias Maraithon.Projects.Project
  alias Maraithon.Repo
  alias Maraithon.TelegramConversations
  alias Maraithon.Todos

  @default_email "reviewer@maraithon.com"
  @seed_prefix "reviewer-seed-"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    email = reviewer_email()

    case Accounts.get_or_create_user_by_email(email) do
      {:ok, user} ->
        seed_people(user.id)
        seed_projects(user.id)
        seed_todos(user.id)
        seed_chat(user.id)
        seed_brief(user.id)

        Mix.shell().info("Seeded reviewer demo account for #{user.id}.")

      {:error, reason} ->
        Mix.raise("Could not create reviewer user #{email}: #{inspect(reason)}")
    end
  end

  defp reviewer_email do
    config = Application.get_env(:maraithon, :app_review_bypass) || []

    case config[:email] do
      value when is_binary(value) and value != "" -> Accounts.normalize_email(value)
      _ -> @default_email
    end
  end

  # ---------------------------------------------------------------------------
  # People
  # ---------------------------------------------------------------------------

  defp seed_people(user_id) do
    [
      %{
        seed_id: "person-1",
        display_name: "Emma Hayes",
        first_name: "Emma",
        last_name: "Hayes",
        relationship: "spouse",
        communication_frequency: "daily",
        relationship_strength: 95,
        contact_details: %{"emails" => ["emma.hayes@example.com"]},
        notes: "Wife. Coordinates family logistics and weekend plans."
      },
      %{
        seed_id: "person-2",
        display_name: "Charlie Feng",
        first_name: "Charlie",
        last_name: "Feng",
        relationship: "colleague",
        communication_frequency: "daily",
        relationship_strength: 80,
        contact_details: %{"emails" => ["charlie@runner.example"]},
        notes: "Engineering lead. Owns the trial-gating and platform work."
      },
      %{
        seed_id: "person-3",
        display_name: "Jane Thuet",
        first_name: "Jane",
        last_name: "Thuet",
        relationship: "client",
        communication_frequency: "weekly",
        relationship_strength: 60,
        contact_details: %{"emails" => ["jane@acme.example"]},
        notes: "Prospect at Acme. Evaluating the Team plan."
      },
      %{
        seed_id: "person-4",
        display_name: "Laura Niblett",
        first_name: "Laura",
        last_name: "Niblett",
        relationship: "vendor",
        communication_frequency: "monthly",
        relationship_strength: 45,
        contact_details: %{"emails" => ["laura@benefits.example"]},
        notes: "Benefits broker. Handles the company insurance renewal."
      },
      %{
        seed_id: "person-5",
        display_name: "Sam Rivera",
        first_name: "Sam",
        last_name: "Rivera",
        relationship: "friend",
        communication_frequency: "weekly",
        relationship_strength: 70,
        contact_details: %{"emails" => ["sam.rivera@example.com"]},
        notes: "Close friend. Usual squash partner on Thursdays."
      }
    ]
    |> Enum.each(fn attrs -> upsert_person(user_id, attrs) end)
  end

  defp upsert_person(user_id, %{seed_id: seed_id} = attrs) do
    metadata = %{"seed_id" => seed_id, "seed" => "reviewer"}

    person_attrs =
      attrs
      |> Map.drop([:seed_id])
      |> Map.put(:metadata, metadata)

    case find_seeded(Person, user_id, seed_id) do
      %Person{} = person -> Crm.update_person(person, person_attrs)
      nil -> Crm.create_person(user_id, person_attrs)
    end
  end

  # ---------------------------------------------------------------------------
  # Projects
  # ---------------------------------------------------------------------------

  defp seed_projects(user_id) do
    [
      %{
        seed_id: "project-1",
        name: "Q3 Product Launch",
        status: "active",
        priority: "high",
        summary: "Ship the new onboarding flow and pricing page before the Q3 push."
      },
      %{
        seed_id: "project-2",
        name: "Benefits Renewal",
        status: "active",
        priority: "normal",
        summary: "Finalize the company health plan renewal with the broker."
      },
      %{
        seed_id: "project-3",
        name: "Family Summer Plans",
        status: "active",
        priority: "normal",
        summary: "Camp signups, travel, and the calendar for the kids' summer."
      }
    ]
    |> Enum.each(fn attrs -> upsert_project(user_id, attrs) end)
  end

  defp upsert_project(user_id, %{seed_id: seed_id} = attrs) do
    metadata = %{"seed_id" => seed_id, "seed" => "reviewer"}

    project_attrs =
      attrs
      |> Map.drop([:seed_id])
      |> Map.put(:metadata, metadata)

    case find_seeded(Project, user_id, seed_id) do
      %Project{} = project -> Projects.update_project(project, project_attrs)
      nil -> Projects.create_project(user_id, project_attrs)
    end
  end

  # ---------------------------------------------------------------------------
  # Todos (Today / Work)
  # ---------------------------------------------------------------------------

  defp seed_todos(user_id) do
    now = DateTime.utc_now()

    attrs_list =
      [
        {"Reply to Jane Thuet about the Team plan",
         "Jane at Acme is waiting on pricing for the Team plan.",
         "Send Jane the Team plan pricing and a scheduling link.", "work", hours(now, 3)},
        {"Confirm the benefits renewal with Laura",
         "Laura needs the signed renewal before the deadline this week.",
         "Review the renewal terms and reply to Laura with sign-off.", "work", hours(now, 6)},
        {"Align with Charlie on trial gating",
         "Engineering needs a decision on the 3-day trial limit.",
         "Decide the trial-gating approach and reply in the thread.", "work", hours(now, 5)},
        {"Sign Jack up for summer camp", "Registration for the kids' summer camp closes Friday.",
         "Complete the camp registration form online.", "personal", hours(now, 30)},
        {"Plan the weekend with Emma", "Emma asked about Saturday plans for the family.",
         "Text Emma to lock in Saturday's plan.", "personal", hours(now, 8)},
        {"Squash with Sam Thursday", "Standing Thursday squash game with Sam.",
         "Confirm the court booking with Sam for Thursday.", "personal", hours(now, 48)},
        {"Review the launch checklist", "The Q3 launch checklist has open items before go-live.",
         "Walk the launch checklist and assign the remaining items.", "work", hours(now, 24)},
        {"Approve the updated pricing page copy",
         "Marketing sent the new pricing page copy for sign-off.",
         "Read the pricing copy and approve or request edits.", "work", hours(now, 12)},
        {"Call the dentist about Emma's appointment",
         "Need to reschedule Emma's dental appointment.",
         "Call the dentist to move the appointment to next week.", "personal", hours(now, 20)},
        {"Prep notes for the Acme demo",
         "The Acme demo is coming up and needs a tailored walkthrough.",
         "Draft the demo script focused on Acme's use case.", "work", hours(now, 18)}
      ]
      |> Enum.with_index(1)
      |> Enum.map(fn {{title, summary, next_action, life_domain, due_at}, index} ->
        %{
          "dedupe_key" => "#{@seed_prefix}todo-#{index}",
          "source" => "chief_of_staff_morning_briefing",
          "kind" => "general",
          "attention_mode" => "act_now",
          "title" => title,
          "summary" => summary,
          "next_action" => next_action,
          "due_at" => due_at,
          "metadata" => %{"seed" => "reviewer", "life_domain" => life_domain}
        }
      end)

    Todos.upsert_many(user_id, attrs_list)
  end

  # ---------------------------------------------------------------------------
  # Chat
  # ---------------------------------------------------------------------------

  defp seed_chat(user_id) do
    client_thread_id = "#{@seed_prefix}chat"

    conversation =
      case TelegramConversations.list_mobile_threads(user_id) do
        threads when is_list(threads) ->
          Enum.find(threads, fn thread ->
            get_in(thread.metadata, ["client_thread_id"]) == client_thread_id
          end)

        _ ->
          nil
      end

    conversation =
      conversation ||
        case TelegramConversations.create_mobile_thread(user_id, %{
               "client_thread_id" => client_thread_id,
               "title" => "Getting started",
               "metadata" => %{"seed" => "reviewer"}
             }) do
          {:ok, created} -> created
          {:error, _reason} -> nil
        end

    if conversation && turns_count(conversation.id) == 0 do
      [
        {"user", "What should I focus on today?"},
        {"assistant",
         "You have three time-sensitive items: reply to Jane Thuet about the Team plan, " <>
           "confirm the benefits renewal with Laura, and align with Charlie on trial gating. " <>
           "Jane has been waiting longest — start there."},
        {"user", "Draft a reply to Jane."},
        {"assistant",
         "Here's a draft: \"Hi Jane — thanks for your patience. The Team plan is $X/seat/month " <>
           "with volume pricing above 25 seats. Here's a link to grab time this week so I can " <>
           "walk you through it. Looking forward to it!\" Want me to send it?"},
        {"user", "How's the launch tracking?"},
        {"assistant",
         "The Q3 Product Launch is on track but has two open checklist items: the pricing page " <>
           "copy is waiting on your approval, and the onboarding flow needs a final QA pass. " <>
           "Clearing the copy approval today keeps marketing unblocked."}
      ]
      |> Enum.with_index()
      |> Enum.each(fn {{role, text}, index} ->
        TelegramConversations.append_turn(conversation, %{
          "role" => role,
          "text" => text,
          "turn_kind" => if(role == "user", do: "user_message", else: "assistant_reply"),
          "origin_type" => "chat",
          "client_message_id" => "#{@seed_prefix}chat-msg-#{index}"
        })
      end)
    end
  end

  defp turns_count(conversation_id) do
    import Ecto.Query
    alias Maraithon.TelegramConversations.Turn

    Repo.aggregate(from(t in Turn, where: t.conversation_id == ^conversation_id), :count)
  end

  # ---------------------------------------------------------------------------
  # Morning brief
  # ---------------------------------------------------------------------------

  defp seed_brief(user_id) do
    agent = ensure_reviewer_agent(user_id)
    now = DateTime.utc_now()

    body = """
    Today is a focused day: clear the three customer and benefits items before family logistics this evening.

    Weather (Toronto): partly cloudy, 22°C now, high 25° / low 16°, 10% chance of rain.

    ## Needs Your Attention
    - **Jane Thuet is waiting on Team plan pricing** — she has been the longest-waiting thread. Send pricing and a scheduling link this morning.
    - **Benefits renewal needs sign-off** — Laura needs the signed renewal before the deadline this week.
    - **Trial gating decision** — Charlie is blocked on the 3-day trial limit; make the call so engineering can ship.

    ## Today's Schedule
    - **10:00** — Acme demo prep. Tailor the walkthrough to Jane's use case.
    - **15:00** — Engineering sync with Charlie on trial economics.

    ## Top Headlines
    - **New foundation model raises pricing pressure** (Techmeme) — useful backdrop for the Team plan conversation with Jane.
    - **Benefits costs rising sector-wide** (NYT) — context for the renewal call with Laura.

    Today's move: clear the Jane and Laura items in your first desk block before opening lower-signal work.
    """

    attrs = %{
      "cadence" => "morning",
      "title" => "Friday — Customer day, clear the waiting threads first",
      "summary" =>
        "Three time-sensitive items lead the day: Team plan pricing for Jane, the benefits renewal, and the trial-gating decision.",
      "body" => String.trim(body),
      "status" => "sent",
      "scheduled_for" => now,
      "sent_at" => now,
      "dedupe_key" => "#{@seed_prefix}brief-morning",
      "metadata" => %{"seed" => "reviewer"}
    }

    Briefs.record(user_id, agent.id, attrs)
  end

  defp ensure_reviewer_agent(user_id) do
    import Ecto.Query
    alias Maraithon.Agents.Agent

    existing =
      Repo.one(
        from(a in Agent,
          where: a.user_id == ^user_id,
          where: fragment("?->>'seed' = ?", a.config, "reviewer"),
          limit: 1
        )
      )

    existing ||
      Repo.insert!(
        Agent.changeset(%Agent{user_id: user_id}, %{
          behavior: "ai_chief_of_staff",
          status: "stopped",
          config: %{"seed" => "reviewer", "user_id" => user_id}
        })
      )
  end

  # ---------------------------------------------------------------------------
  # Shared
  # ---------------------------------------------------------------------------

  defp find_seeded(schema, user_id, seed_id) do
    import Ecto.Query

    Repo.one(
      from(row in schema,
        where: row.user_id == ^user_id,
        where: fragment("?->>'seed_id' = ?", row.metadata, ^seed_id),
        limit: 1
      )
    )
  end

  defp hours(now, count), do: DateTime.add(now, count * 3600, :second)
end
