defmodule Maraithon.Todos.MeetingRelevance do
  @moduledoc """
  Product-wide admission and expiry rules for automatically discovered meeting
  work. Calendar attendance is not a todo; a separate deliverable can be.
  """

  @version 1
  @manual_sources ~w(manual mobile user)
  @meeting ~r/\b(meeting|call|appointment|session|deep[ -]dive|stand[ -]?up|sync|interview|demo|webinar|conference|workshop)\b/i
  @attendance ~r/^(?:(?:please|you should|you need to|remember to)\s+)?(?:join|attend|go to|participate in|show up for|dial into|dial in to|log into|be at)\b/i
  @preparation ~r/^(?:prep(?:are)?\s+(?:for|to attend)\b|rsvp\b|(?:accept|decline|respond to)\b.*\b(?:invite|invitation)\b|confirm\b.*\battendance\b)/i
  @separate_action ~r/\b(?:and|then|to)\s+(?:send|deliver|submit|write|prepare|review|decide|approve|resolve|fix|pay)\b/i

  def version, do: @version

  @doc "Shared instructions for discovery and intake, independent of user preferences."
  def prompt_rules do
    """
    Calendar relevance is a product rule for every user:
    - Never create a todo merely to attend, join, remember, or show up for a
      scheduled meeting, call, appointment, or event. Attendance belongs in the
      calendar and daily schedule, even for important or optional invitations
      received through Gmail, Slack, or another source.
    - Judge relevance at CURRENT time, using the event's actual date, timezone,
      and latest reschedule/cancellation evidence. Message arrival, a reminder,
      or this scan's timestamp does not make an old event current.
    - Skip past/cancelled-event attendance, preparation, RSVP, and invitation
      responses whose opportunity has passed. No proof of attendance is needed
      to decide that an old invitation is no longer actionable. Do not ask the
      user whether to keep those reminders, or invent a follow-up to retain them.
    - Keep separate, source-backed work such as sending requested redlines,
      preparing an explicitly requested deliverable for an upcoming meeting,
      resolving a scheduling problem, or following through on a real commitment.
      A meeting ending does not itself prove a deliverable was completed or that
      a promised follow-up is obsolete. Never dismiss ordinary overdue work.
    - For work useful ONLY before a particular event, preserve metadata.calendar_action
      with kind "preparation" or "rsvp", event_start_at and event_end_at as
      source-grounded ISO-8601 instants with timezone, and event_id/source_ref
      when known. Use kind "follow_up" or "deliverable" for obligations that
      survive the meeting. Never invent an event timestamp from a message date.
    """
  end

  @doc "Returns a policy reason only when the item is unambiguously ineligible."
  def reason(attrs, opts \\ []) when is_map(attrs) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    metadata = field(attrs, :metadata) || %{}
    action = field(metadata, :calendar_action) || %{}
    title = text(field(attrs, :title))
    next_action = text(field(attrs, :next_action))
    context = Enum.join([title, next_action, text(field(attrs, :summary))], " ")
    kind = field(action, :kind)

    event_action? =
      kind in ["preparation", "rsvp"] or
        (Regex.match?(@meeting, context) and Regex.match?(@preparation, title))

    cond do
      manual?(attrs, metadata) ->
        nil

      kind == "attendance" ->
        "calendar_attendance"

      Regex.match?(@meeting, context) and Regex.match?(@attendance, title) and
          not Regex.match?(@separate_action, title) ->
        "calendar_attendance"

      kind in ["deliverable", "follow_up"] ->
        nil

      event_action? and cancelled?(metadata, action) ->
        "cancelled_meeting_action"

      event_action? and event_started?(attrs, metadata, action, now) ->
        "expired_meeting_action"

      true ->
        nil
    end
  end

  def note("calendar_attendance"),
    do: "Removed because meeting attendance belongs on your calendar, not in Todos."

  def note("expired_meeting_action"),
    do: "Removed because this meeting's preparation or response window has passed."

  def note("cancelled_meeting_action"),
    do:
      "Removed because the meeting was cancelled and this preparation or response is no longer needed."

  defp cancelled?(metadata, action) do
    event = field(metadata, :calendar_event) || field(metadata, :event) || %{}
    (field(action, :event_status) || field(event, :status)) in ["cancelled", "canceled"]
  end

  defp manual?(attrs, metadata) do
    field(attrs, :source) in @manual_sources or
      field(metadata, :explicit_user_request) == true or field(metadata, :user_requested) == true
  end

  defp event_started?(attrs, metadata, action, now) do
    event = field(metadata, :calendar_event) || field(metadata, :event) || %{}
    source_record = field(metadata, :source_record) || %{}

    candidates = [
      field(action, :event_start_at),
      field(metadata, :event_start_at),
      field(metadata, :meeting_start_at),
      field(event, :start_at),
      field(event, :start),
      if(field(attrs, :source) in ~w(calendar google_calendar local_calendar),
        do: field(source_record, :start_at) || field(source_record, :start)
      )
    ]

    case Enum.find_value(candidates, &instant/1) do
      %DateTime{} = start -> DateTime.compare(start, now) != :gt
      _ -> false
    end
  end

  defp instant(%DateTime{} = at), do: at
  defp instant(%{} = value), do: instant(Map.get(value, "dateTime"))

  defp instant(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  defp instant(_), do: nil

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_, _), do: nil
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_), do: ""
end
