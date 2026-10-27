defmodule Maraithon.Briefs.Email do
  @moduledoc """
  Delivers the morning brief to the user's inbox.

  The email carries the brief headline and body plus a CTA into the web
  briefing page, making the briefing a daily ritual the user can act on.
  Delivery is idempotent per brief via `metadata.email_sent_at`.
  """

  import Ecto.Changeset, only: [change: 2]

  alias Maraithon.AppUrl
  alias Maraithon.Briefs.Brief
  alias Maraithon.Briefs.Markdown
  alias Maraithon.EmailDelivery
  alias Maraithon.Repo

  require Logger

  @doc """
  Sends the brief by email when it is a morning brief that has not been
  emailed yet. Best-effort: failures are logged, never raised.
  """
  def maybe_deliver(%Brief{cadence: "morning"} = brief) do
    cond do
      email_sent?(brief) -> :skip
      not EmailDelivery.configured?() -> :skip
      true -> deliver(brief)
    end
  end

  def maybe_deliver(_brief), do: :skip

  defp deliver(%Brief{} = brief) do
    to = recipient(brief.user_id)

    if is_nil(to) do
      :skip
    else
      case EmailDelivery.send(to, content(brief)) do
        :ok ->
          mark_email_sent(brief)
          :ok

        other ->
          Logger.warning("Morning brief email not delivered",
            brief_id: brief.id,
            result: inspect(other)
          )

          :error
      end
    end
  rescue
    exception ->
      Logger.warning("Morning brief email crashed",
        brief_id: brief.id,
        reason: Exception.message(exception)
      )

      :error
  end

  # User ids are email addresses in this system; fall back gracefully if
  # that ever changes.
  defp recipient(user_id) when is_binary(user_id) do
    if String.contains?(user_id, "@"), do: user_id
  end

  defp recipient(_user_id), do: nil

  defp email_sent?(%Brief{metadata: metadata}) do
    is_map(metadata) and is_binary(metadata["email_sent_at"])
  end

  defp mark_email_sent(%Brief{} = brief) do
    metadata =
      brief.metadata
      |> Kernel.||(%{})
      |> Map.put("email_sent_at", DateTime.utc_now() |> DateTime.to_iso8601())

    brief
    |> change(%{metadata: metadata})
    |> Repo.update()
  end

  defp content(%Brief{} = brief) do
    briefing_url = AppUrl.url("/briefing")
    title = brief.title || "Your morning briefing"
    summary = brief.summary || ""
    body = brief.body || ""

    %{
      subject: title,
      text_body: """
      #{title}

      #{summary}

      #{Markdown.to_text(body)}

      Open your briefing and take action:
      #{briefing_url}
      """,
      html_body: """
      <!DOCTYPE html>
      <html>
        <body style="margin:0;padding:0;background-color:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
          <div style="max-width:560px;margin:0 auto;padding:32px 20px;">
            <div style="background:#ffffff;border-radius:12px;padding:32px;border:1px solid #e4e4e7;">
              <p style="margin:0 0 4px;font-size:13px;letter-spacing:0.04em;text-transform:uppercase;color:#71717a;">Morning briefing</p>
              <h1 style="margin:0 0 12px;font-size:22px;line-height:1.3;color:#18181b;">#{escape(title)}</h1>
              <p style="margin:0 0 20px;font-size:15px;line-height:1.5;color:#3f3f46;">#{escape(summary)}</p>
              <div style="font-size:14px;line-height:1.6;color:#3f3f46;">#{Markdown.to_html(body)}</div>
              <a href="#{briefing_url}" style="display:inline-block;margin-top:24px;background:#18181b;color:#ffffff;text-decoration:none;font-size:15px;font-weight:600;padding:12px 24px;border-radius:8px;">Open your briefing</a>
            </div>
            <p style="margin:16px 4px 0;font-size:12px;color:#a1a1aa;">Sent by Maraithon, your chief of staff.</p>
          </div>
        </body>
      </html>
      """
    }
  end

  defp escape(value) when is_binary(value) do
    value
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp escape(_value), do: ""
end
