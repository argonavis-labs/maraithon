defmodule MaraithonWeb.MarketingHTML do
  use MaraithonWeb, :html

  embed_templates "marketing_html/*"

  @doc """
  Marketing-page chrome: olive-themed nav + footer with a content slot.
  """
  attr :title, :string, required: true
  attr :eyebrow, :string, default: nil
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <div class="min-h-screen bg-olive-100 font-sans text-olive-950 antialiased">
      <header class="absolute inset-x-0 top-0 z-10">
        <nav
          class="mx-auto flex max-w-7xl items-center justify-between px-6 py-6 lg:px-8"
          aria-label="Global"
        >
          <a href="/" class="flex items-center gap-3">
            <span class="flex size-9 items-center justify-center rounded-lg bg-olive-950 text-olive-50">
              <svg viewBox="0 0 16 16" class="size-5 fill-current" aria-hidden="true">
                <path d="M2.5 2h2.4l3.1 5.4L11.1 2h2.4v12h-1.9V5.5L8.6 11.1H7.4L4.4 5.5V14H2.5V2Z" />
              </svg>
            </span>
            <span class="font-display text-2xl text-olive-950">Maraithon</span>
          </a>
          <div class="hidden gap-8 text-sm/6 text-olive-700 sm:flex">
            <a href="/#features" class="hover:text-olive-950">Features</a>
            <a href="/support" class="hover:text-olive-950">Support</a>
            <a href="/privacy" class="hover:text-olive-950">Privacy</a>
            <a href="/terms" class="hover:text-olive-950">Terms</a>
          </div>
          <a
            href="/login"
            class="inline-flex items-center rounded-md bg-olive-950 px-3.5 py-2 text-sm/6 font-medium text-olive-50 hover:bg-olive-800"
          >
            Sign in
          </a>
        </nav>
      </header>

      <main class="pt-32 pb-24 sm:pt-40">
        <article class="mx-auto max-w-3xl px-6 lg:px-8">
          <header class="mb-12 border-b border-olive-200 pb-8">
            <%= if @eyebrow do %>
              <p class="text-sm/6 font-medium uppercase tracking-wider text-olive-600">{@eyebrow}</p>
            <% end %>
            <h1 class="mt-2 font-display text-5xl tracking-tight text-olive-950 sm:text-6xl">
              {@title}
            </h1>
          </header>
          <div class="prose-marketing text-base/7 text-olive-800">
            {render_slot(@inner_block)}
          </div>
        </article>
      </main>

      <footer class="border-t border-olive-200 bg-olive-950 text-olive-300">
        <div class="mx-auto max-w-7xl px-6 py-12 lg:px-8">
          <div class="flex flex-col items-start justify-between gap-3 text-xs/6 text-olive-400 sm:flex-row">
            <p>&copy; {DateTime.utc_now().year} ArgoNavis Inc. All rights reserved.</p>
            <div class="flex gap-5">
              <a href="/privacy" class="hover:text-olive-50">Privacy</a>
              <a href="/terms" class="hover:text-olive-50">Terms</a>
              <a href="/support" class="hover:text-olive-50">Support</a>
            </div>
          </div>
        </div>
      </footer>
    </div>
    """
  end
end
