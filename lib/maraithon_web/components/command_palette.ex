defmodule MaraithonWeb.Components.CommandPalette do
  @moduledoc """
  Global command palette for the authenticated app shell.

  The palette is intentionally client-side: the command set is small,
  static, and route-backed, so opening and filtering should feel
  instant from any page.
  """

  use MaraithonWeb, :html

  attr :current_path, :string, default: "/dashboard"
  attr :current_user, :map, default: nil

  def command_palette(assigns) do
    normalized_path = normalize_path(assigns.current_path)

    commands =
      normalized_path
      |> command_items(assigns.current_user)
      |> Enum.with_index()
      |> Enum.map(fn {command, index} ->
        command
        |> Map.put(:index, index)
        |> Map.put_new(:shortcut, nil)
        |> Map.put_new(:priority, 50)
        |> Map.put(:current_page, current_page?(normalized_path, command))
        |> Map.put(:search, command_search(command))
      end)
      |> Enum.sort_by(&{-&1.priority, &1.group, &1.label})

    assigns =
      assigns
      |> assign(:commands, commands)
      |> assign(:normalized_path, normalized_path)

    ~H"""
    <div
      id="maraithon-command-palette"
      class="fixed inset-0 z-50 hidden"
      data-open="false"
      aria-hidden="true"
    >
      <div
        class="absolute inset-0 bg-zinc-950/35"
        data-command-palette-backdrop="true"
        aria-hidden="true"
      />
      <div class="relative mx-auto flex min-h-full w-full max-w-3xl items-start px-3 pt-[12vh] sm:px-6">
        <div
          class="w-full overflow-hidden rounded-lg border border-zinc-950/10 bg-white shadow-xl ring-1 ring-zinc-950/5"
          role="dialog"
          aria-modal="true"
          aria-label="Command palette"
        >
          <div class="flex items-center gap-3 border-b border-zinc-950/10 px-4 py-3">
            <MaraithonWeb.Components.Sidebar.icon name={:search} class="size-5 text-zinc-400" />
            <input
              id="maraithon-command-palette-input"
              type="search"
              autocomplete="off"
              spellcheck="false"
              placeholder="Type a command or search..."
              class="min-w-0 flex-1 border-0 bg-transparent p-0 text-base/6 text-zinc-950 placeholder:text-zinc-400 focus:outline-none focus:ring-0 sm:text-sm/6"
            />
            <kbd class="hidden rounded border border-zinc-950/10 bg-zinc-50 px-1.5 py-0.5 text-[11px]/5 font-medium text-zinc-500 sm:inline">
              Esc
            </kbd>
          </div>

          <div
            id="maraithon-command-palette-list"
            class="max-h-[min(60vh,32rem)] overflow-y-auto py-2"
            role="listbox"
            aria-label="Commands"
          >
            <a
              :for={command <- @commands}
              href={command.href}
              class="group flex items-center gap-3 px-4 py-3 text-left text-sm/6 text-zinc-700 hover:bg-zinc-950/[0.04] data-[active=true]:bg-zinc-950/[0.06]"
              data-command-palette-item="true"
              data-command-label={command.label}
              data-command-search={command.search}
              data-command-priority={command.priority}
              data-command-current={if command.current_page, do: "true", else: "false"}
              data-command-index={command.index}
              role="option"
              aria-selected="false"
            >
              <span class="flex size-8 shrink-0 items-center justify-center rounded-md bg-zinc-950/[0.04] text-zinc-500 group-data-[active=true]:bg-white group-data-[active=true]:text-zinc-950">
                <MaraithonWeb.Components.Sidebar.icon name={command.icon} class="size-5" />
              </span>
              <span class="min-w-0 flex-1">
                <span class="flex min-w-0 items-center gap-2">
                  <span class="truncate font-medium text-zinc-950"><%= command.label %></span>
                  <span
                    :if={command.current_page}
                    class="shrink-0 rounded bg-blue-50 px-1.5 py-0.5 text-[11px]/4 font-medium text-blue-700 ring-1 ring-blue-700/10"
                  >
                    Current
                  </span>
                </span>
                <span class="mt-0.5 block truncate text-xs/5 text-zinc-500">
                  <%= command.description %>
                </span>
              </span>
              <span class="hidden shrink-0 items-center gap-2 sm:flex">
                <span class="rounded bg-zinc-950/[0.04] px-1.5 py-0.5 text-[11px]/5 font-medium text-zinc-500">
                  <%= command.group %>
                </span>
                <kbd
                  :if={command.shortcut}
                  class="rounded border border-zinc-950/10 bg-white px-1.5 py-0.5 text-[11px]/5 font-medium text-zinc-500"
                >
                  <%= command.shortcut %>
                </kbd>
              </span>
            </a>

            <div
              id="maraithon-command-palette-empty"
              hidden
              class="px-4 py-10 text-center text-sm/6 text-zinc-500"
            >
              No commands found.
            </div>
          </div>

          <div class="flex items-center justify-between border-t border-zinc-950/10 px-4 py-2 text-xs/5 text-zinc-500">
            <span>Navigate</span>
            <span class="flex items-center gap-2">
              <kbd class="rounded border border-zinc-950/10 bg-zinc-50 px-1.5 py-0.5 font-medium">Up/Down</kbd>
              <kbd class="rounded border border-zinc-950/10 bg-zinc-50 px-1.5 py-0.5 font-medium">Enter</kbd>
            </span>
          </div>
        </div>
      </div>
    </div>

    <script>
      (() => {
        if (window.MaraithonCommandPaletteInitialized) return
        window.MaraithonCommandPaletteInitialized = true

        const rootId = "maraithon-command-palette"
        const inputId = "maraithon-command-palette-input"
        const itemSelector = "[data-command-palette-item='true']"

        const root = () => document.getElementById(rootId)
        const input = () => document.getElementById(inputId)
        const items = () => Array.from(document.querySelectorAll(itemSelector))
        const emptyState = () => document.getElementById("maraithon-command-palette-empty")
        const paletteOpen = () => root()?.dataset.open === "true"

        const textFor = (item) => (item.dataset.commandSearch || "").toLowerCase()
        const priorityFor = (item) => Number.parseInt(item.dataset.commandPriority || "0", 10)

        const typingTarget = (target) => {
          if (!target) return false
          if (target.id === inputId) return false
          const tag = target.tagName
          return target.isContentEditable || tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT"
        }

        const setActive = (visibleItems, index) => {
          visibleItems.forEach((item, itemIndex) => {
            const active = itemIndex === index
            item.dataset.active = active ? "true" : "false"
            item.setAttribute("aria-selected", active ? "true" : "false")
          })

          visibleItems[index]?.scrollIntoView({ block: "nearest" })
        }

        const visibleItems = () => items().filter((item) => !item.hidden)

        const filterItems = () => {
          const query = (input()?.value || "").trim().toLowerCase()
          const terms = query.split(/\s+/).filter(Boolean)

          const scored = items().map((item) => {
            const haystack = textFor(item)
            const label = (item.dataset.commandLabel || "").toLowerCase()
            const matches = terms.every((term) => haystack.includes(term))
            let score = priorityFor(item)

            if (item.dataset.commandCurrent === "true") score += 25
            if (query && label.startsWith(query)) score += 80
            if (query && haystack.includes(query)) score += 20

            return { item, matches, score, index: Number.parseInt(item.dataset.commandIndex || "0", 10) }
          })

          scored.forEach(({ item, matches }) => {
            item.hidden = !matches
            item.dataset.active = "false"
            item.setAttribute("aria-selected", "false")
          })

          scored
            .filter(({ matches }) => matches)
            .sort((left, right) => (right.score - left.score) || (left.index - right.index))
            .forEach(({ item }) => item.parentElement.appendChild(item))

          const visible = visibleItems()
          const empty = emptyState()
          if (empty) empty.hidden = visible.length !== 0
          setActive(visible, 0)
        }

        const openPalette = () => {
          const palette = root()
          if (!palette) return
          palette.classList.remove("hidden")
          palette.dataset.open = "true"
          palette.setAttribute("aria-hidden", "false")
          document.documentElement.classList.add("overflow-hidden")
          window.requestAnimationFrame(() => {
            input()?.focus()
            input()?.select()
            filterItems()
          })
        }

        const closePalette = () => {
          const palette = root()
          if (!palette) return
          palette.dataset.open = "false"
          palette.setAttribute("aria-hidden", "true")
          palette.classList.add("hidden")
          document.documentElement.classList.remove("overflow-hidden")
        }

        const moveActive = (direction) => {
          const visible = visibleItems()
          if (visible.length === 0) return
          const currentIndex = Math.max(0, visible.findIndex((item) => item.dataset.active === "true"))
          const nextIndex = (currentIndex + direction + visible.length) % visible.length
          setActive(visible, nextIndex)
        }

        document.addEventListener("keydown", (event) => {
          const isCommandK = (event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k"

          if (isCommandK && !typingTarget(event.target)) {
            event.preventDefault()
            paletteOpen() ? closePalette() : openPalette()
            return
          }

          if (!paletteOpen()) return

          if (event.key === "Escape") {
            event.preventDefault()
            closePalette()
            return
          }

          if (event.key === "ArrowDown") {
            event.preventDefault()
            moveActive(1)
            return
          }

          if (event.key === "ArrowUp") {
            event.preventDefault()
            moveActive(-1)
            return
          }

          if (event.key === "Enter") {
            const active = visibleItems().find((item) => item.dataset.active === "true")
            if (active) {
              event.preventDefault()
              active.click()
            }
          }
        })

        document.addEventListener("input", (event) => {
          if (event.target?.id === inputId) filterItems()
        })

        document.addEventListener("mouseover", (event) => {
          const item = event.target?.closest?.(itemSelector)
          if (!item || !paletteOpen()) return
          const visible = visibleItems()
          setActive(visible, visible.indexOf(item))
        })

        document.addEventListener("click", (event) => {
          if (event.target?.closest?.("[data-command-palette-trigger='true']")) {
            event.preventDefault()
            openPalette()
            return
          }

          if (event.target?.dataset?.commandPaletteBackdrop === "true") {
            closePalette()
          }
        })
      })()
    </script>
    """
  end

  defp command_items(current_path, current_user) do
    current_path
    |> context_commands()
    |> Kernel.++(chief_of_staff_commands())
    |> Kernel.++(todo_commands())
    |> Kernel.++(people_commands())
    |> Kernel.++(connector_commands())
    |> Kernel.++(agent_commands())
    |> Kernel.++(navigation_commands())
    |> Kernel.++(admin_commands(current_user))
    |> dedupe_commands()
  end

  defp context_commands("/dashboard") do
    [
      command("Review today's work", "/dashboard#todos", :todos, "Suggested",
        description: "Jump to the one-by-one chief-of-staff work review.",
        keywords: "today review one by one dashboard work",
        priority: 145
      ),
      command("Open full work queue", "/todos", :todos, "Suggested",
        description: "Open the searchable work queue.",
        keywords: "work queue filters search",
        priority: 135
      ),
      command("Create an automation", "/agents/new", :plus, "Suggested",
        description: "Start a new chief-of-staff automation.",
        keywords: "new automation create install",
        priority: 125
      )
    ]
  end

  defp context_commands("/todos") do
    [
      command("Needs action work", "/todos?status=active&attention=act_now", :todos, "Suggested",
        description: "Open active items that need a decision, reply, or next step.",
        keywords: "action urgent decide reply active work",
        priority: 150
      ),
      command("Past-due work", "/todos?status=active&due=overdue", :todos, "Suggested",
        description: "Show active work past its due time.",
        keywords: "late stale overdue due date work",
        priority: 145
      ),
      command("Work due today", "/todos?status=active&due=today", :todos, "Suggested",
        description: "Show active work due today.",
        keywords: "today deadline due now work",
        priority: 140
      )
    ]
  end

  defp context_commands("/operator/people") do
    [
      command("Merge contacts", "/operator/people", :people, "Suggested",
        description: "Select duplicate people, then merge them from bulk actions.",
        keywords: "people contacts duplicates merge same person",
        priority: 150
      ),
      command("Update relationship context", "/operator/people", :people, "Suggested",
        description:
          "Classify family, business, investor, customer, vendor, or friend relationships.",
        keywords: "relationship context family business labels classify",
        priority: 145
      ),
      command(
        "Open relationship context",
        "/operator/memories?kind=relationship",
        :memory,
        "Suggested",
        description: "Review learned relationship facts and corrections.",
        keywords: "memory relationship facts corrections",
        priority: 135
      )
    ]
  end

  defp context_commands("/operator/memories") do
    [
      command("Active saved context", "/operator/memories?status=active", :memory, "Suggested",
        description: "Show facts currently used by Maraithon.",
        keywords: "active memory facts",
        priority: 145
      ),
      command(
        "Relationship context",
        "/operator/memories?kind=relationship",
        :memory,
        "Suggested",
        description: "Show context about people and relationship handling.",
        keywords: "relationship people crm memory",
        priority: 140
      ),
      command("Saved corrections", "/operator/memories?kind=correction", :memory, "Suggested",
        description: "Show feedback Maraithon should honor next time.",
        keywords: "correction feedback learn memory",
        priority: 135
      )
    ]
  end

  defp context_commands("/connectors") do
    [
      command("Connect Google", "/auth/google", :connectors, "Suggested",
        description: "Connect Gmail, Calendar, Contacts, and related Google context.",
        keywords: "google gmail calendar contacts oauth connect",
        priority: 145
      ),
      command("Connect Slack", "/auth/slack", :connectors, "Suggested",
        description: "Connect Slack workspace context and DMs.",
        keywords: "slack connect oauth workspace dm",
        priority: 140
      ),
      command("Review Telegram setup", "/connectors/telegram", :connectors, "Suggested",
        description: "Check proactive delivery and chat setup.",
        keywords: "telegram setup delivery chat proactive",
        priority: 135
      )
    ]
  end

  defp context_commands("/agents") do
    [
      command("New automation", "/agents/new", :plus, "Suggested",
        description: "Create or install an automation.",
        keywords: "create install new automation",
        priority: 145
      ),
      command("Running automations", "/agents?status=running", :agents, "Suggested",
        description: "Show automations currently doing work.",
        keywords: "running active automations status",
        priority: 140
      ),
      command("Automations needing attention", "/agents?status=degraded", :agents, "Suggested",
        description: "Show automations that need attention.",
        keywords: "degraded unhealthy failed automations status",
        priority: 135
      )
    ]
  end

  defp context_commands(current_path) when is_binary(current_path) do
    cond do
      String.starts_with?(current_path, "/todos") ->
        context_commands("/todos")

      String.starts_with?(current_path, "/operator/people") ->
        context_commands("/operator/people")

      String.starts_with?(current_path, "/operator/memories") ->
        context_commands("/operator/memories")

      String.starts_with?(current_path, "/connectors") ->
        context_commands("/connectors")

      String.starts_with?(current_path, "/agents") ->
        context_commands("/agents")

      true ->
        context_commands("/dashboard")
    end
  end

  defp chief_of_staff_commands do
    [
      command("Open chief-of-staff dashboard", "/dashboard", :home, "Chief of Staff",
        description: "Review today's work, active automations, and connected context.",
        keywords: "assistant chief of staff dashboard home briefing proactive",
        priority: 95
      ),
      command("Review work one by one", "/dashboard#todos", :todos, "Chief of Staff",
        description: "Review one item at a time and mark each one done, important, or dismissed.",
        keywords: "work review one at a time done dismiss important",
        priority: 100
      ),
      command(
        "Open saved corrections",
        "/operator/memories?kind=correction",
        :memory,
        "Chief of Staff",
        description: "See feedback Maraithon learned from prior corrections.",
        keywords: "memory correction feedback learn instruction",
        priority: 85
      )
    ]
  end

  defp todo_commands do
    [
      command("All active work", "/todos?status=active", :todos, "Open Work",
        description: "Search, filter, sort, and bulk-manage active work.",
        keywords: "work task active open list queue",
        priority: 90
      ),
      command("Watching work", "/todos?status=active&attention=monitor", :todos, "Open Work",
        description: "Show lower-interruption items being monitored.",
        keywords: "watch monitor low priority passive work",
        priority: 80
      ),
      command("Done work", "/todos?status=done", :todos, "Open Work",
        description: "Review completed items.",
        keywords: "completed finished done work",
        priority: 70
      ),
      command("Dismissed work", "/todos?status=dismissed", :todos, "Open Work",
        description: "Review items dismissed as no longer important.",
        keywords: "dismissed not important archived work",
        priority: 65
      )
    ]
  end

  defp people_commands do
    [
      command("Review relationship insights", "/insights", :insights, "People",
        description: "Review duplicate contacts and relationship suggestions.",
        keywords: "insights duplicates relationships suggestions review",
        priority: 92
      ),
      command("People directory", "/operator/people", :people, "People",
        description: "Manage contacts, relationships, context, and duplicate merges.",
        keywords: "people contacts relationships context merge",
        priority: 90
      ),
      command("Find a person", "/operator/people", :search, "People",
        description: "Search people by name, email, company, or relationship.",
        keywords: "search find person contact who is this",
        priority: 88
      ),
      command("Update relationship labels", "/operator/people", :people, "People",
        description: "Assign family and business relationship context.",
        keywords: "relationship family business customer investor vendor friend label",
        priority: 82
      ),
      command("Relationship context", "/operator/memories?kind=relationship", :memory, "People",
        description: "Review relationship facts used by the assistant.",
        keywords: "relationship memory people facts context",
        priority: 78
      )
    ]
  end

  defp connector_commands do
    [
      command("Connect Google account", "/auth/google", :connectors, "Connected Apps",
        description: "Add Gmail, Calendar, Contacts, and Google account context.",
        keywords: "google gmail calendar contacts connect oauth",
        priority: 78
      ),
      command("Connect Slack workspace", "/auth/slack", :connectors, "Connected Apps",
        description: "Add Slack messages, workspaces, and DMs.",
        keywords: "slack connect oauth workspace messages",
        priority: 76
      ),
      command("Connect Linear", "/auth/linear", :connectors, "Connected Apps",
        description: "Add Linear issues and project context.",
        keywords: "linear connect issues projects oauth",
        priority: 72
      ),
      command("Connect GitHub", "/auth/github", :connectors, "Connected Apps",
        description: "Add GitHub repositories, issues, and pull requests.",
        keywords: "github repos pull requests issues connect",
        priority: 70
      ),
      command("Connect Notion", "/auth/notion", :connectors, "Connected Apps",
        description: "Add Notion workspace context.",
        keywords: "notion docs workspace connect",
        priority: 68
      )
    ]
  end

  defp agent_commands do
    [
      command("Automations", "/agents", :agents, "Automations",
        description: "Inspect installed automations, status, cost, and logs.",
        keywords: "automations status logs cost",
        priority: 84
      ),
      command("New automation", "/agents/new", :plus, "Automations",
        description: "Build, configure, or install a new automation.",
        keywords: "new create install automation builder",
        priority: 82
      )
    ]
  end

  defp navigation_commands do
    [
      command("Dashboard", "/dashboard", :home, "Navigate",
        description: "Today, open work, automations, and workspace overview.",
        keywords: "home dashboard overview today",
        shortcut: "G D",
        priority: 60
      ),
      command("Open Work", "/todos", :todos, "Navigate",
        description: "Search, filter, sort, and bulk-manage open work.",
        keywords: "tasks work queue list table",
        shortcut: "G T",
        priority: 60
      ),
      command("Insights", "/insights", :insights, "Navigate",
        description: "Relationship cleanup and suggestion cards.",
        keywords: "insights duplicate relationship suggestions cards",
        shortcut: "G I",
        priority: 59
      ),
      command("Automations", "/agents", :agents, "Navigate",
        description: "Manage running automations.",
        keywords: "automations status",
        shortcut: "G A",
        priority: 58
      ),
      command("Connected Apps", "/connectors", :connectors, "Navigate",
        description: "Manage connected accounts and services.",
        keywords: "connected apps accounts integrations connectors",
        shortcut: "G C",
        priority: 58
      ),
      command("People", "/operator/people", :people, "Navigate",
        description: "People, relationships, and context.",
        keywords: "people contacts relationships",
        shortcut: "G P",
        priority: 58
      ),
      command("Saved Context", "/operator/memories", :memory, "Navigate",
        description: "Facts, preferences, corrections, and relationship context.",
        keywords: "memory facts preferences corrections relationship",
        shortcut: "G M",
        priority: 55
      ),
      command("How it works", "/how-it-works", :book, "Navigate",
        description: "Read how Maraithon works.",
        keywords: "docs guide help how it works",
        priority: 45
      ),
      command("Changelog", "/changelog", :bolt, "Navigate",
        description: "See recent product changes.",
        keywords: "release notes updates changelog changes",
        priority: 40
      )
    ]
  end

  defp admin_commands(%{is_admin: true}) do
    [
      command("Settings", "/settings", :settings, "Admin",
        description: "Review workspace setup.",
        keywords: "settings admin configuration",
        priority: 54
      ),
      command("Admin dashboard", "/admin", :settings, "Admin",
        description: "Open admin operations.",
        keywords: "admin operations dashboard",
        priority: 52
      ),
      command("Companion devices", "/admin/companion-devices", :connectors, "Admin",
        description: "Manage paired companion devices.",
        keywords: "companion devices admin mobile",
        priority: 50
      )
    ]
  end

  defp admin_commands(_current_user), do: []

  defp command(label, href, icon, group, opts) do
    %{
      id: Keyword.get(opts, :id, command_id(group, label, href)),
      label: label,
      href: href,
      icon: icon,
      group: group,
      description: Keyword.fetch!(opts, :description),
      keywords: Keyword.get(opts, :keywords, ""),
      priority: Keyword.get(opts, :priority, 50),
      shortcut: Keyword.get(opts, :shortcut)
    }
  end

  defp command_id(_group, label, href) do
    [label, href]
    |> Enum.join(":")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp dedupe_commands(commands) do
    commands
    |> Enum.reduce({MapSet.new(), []}, fn command, {seen, acc} ->
      if MapSet.member?(seen, command.id) do
        {seen, acc}
      else
        {MapSet.put(seen, command.id), [command | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp command_search(command) do
    [
      command.label,
      command.group,
      command.description,
      command.href,
      command.keywords,
      command.shortcut
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp current_page?(current_path, %{href: href}) do
    href_path = normalize_path(href)

    cond do
      current_path == href_path -> true
      href_path == "/agents" -> String.starts_with?(current_path, "/agents")
      href_path == "/connectors" -> String.starts_with?(current_path, "/connectors")
      href_path == "/operator/people" -> String.starts_with?(current_path, "/operator/people")
      href_path == "/operator/memories" -> String.starts_with?(current_path, "/operator/memories")
      true -> false
    end
  end

  defp normalize_path(nil), do: "/dashboard"

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.split(["?", "#"], parts: 2)
    |> List.first()
    |> case do
      nil -> "/dashboard"
      "" -> "/dashboard"
      "/" -> "/dashboard"
      value -> value
    end
  end

  defp normalize_path(_path), do: "/dashboard"
end
