defmodule MaraithonWeb.HowItWorksController do
  use MaraithonWeb, :controller

  def index(conn, _params) do
    render(conn, :index,
      page_title: "How it works",
      current_path: ~p"/how-it-works",
      current_user: conn.assigns.current_user,
      stages: stages(),
      principles: principles()
    )
  end

  defp stages do
    [
      %{
        title: "Connect the source",
        description:
          "Connect Gmail, Calendar, Slack, GitHub, or the Mac companion. Maraithon keeps the right context close without asking you to copy it in."
      },
      %{
        title: "Detect what matters",
        description:
          "It looks for open loops, owed replies, calendar pressure, family logistics, and relationship context that could affect your day."
      },
      %{
        title: "Prepare the brief",
        description:
          "Each item is rewritten into a direct summary, why it matters now, and the recommended next move."
      },
      %{
        title: "Offer safe actions",
        description:
          "Where a reply, reminder, or follow-up is possible, Maraithon drafts the move and asks before anything is sent."
      },
      %{
        title: "Learn from your calls",
        description:
          "Dismissals, completions, and saved preferences teach Maraithon what to surface next."
      }
    ]
  end

  defp principles do
    [
      "Lead with what requires action, not a long preamble.",
      "Show why now, the relevant source context, and the recommended next move.",
      "Ask before sending external messages or changing connected work.",
      "Keep family logistics distinct from work follow-ups.",
      "Make every item easy to dismiss, snooze, complete, or correct."
    ]
  end
end
