defmodule Maraithon.PeopleNetwork.Sources do
  @moduledoc "Bounded, read-only source pages for the independent network projection."
  import Ecto.Query
  alias Maraithon.Crm.Observation
  alias Maraithon.LocalCalendar.LocalEvent
  alias Maraithon.LocalMessages.LocalMessage
  alias Maraithon.PeopleNetwork.{Identity, ReadRepo}

  @page_size 1_000

  def reduce(user_id, now, acc, reducer) do
    since = DateTime.add(now, -180, :day)
    horizon = DateTime.add(now, 21, :day)
    deadline = System.monotonic_time(:millisecond) + 90_000

    messages =
      from m in LocalMessage,
        where: m.user_id == ^user_id and m.sent_at >= ^since and m.sent_at <= ^now,
        select: %{
          id: m.id,
          at: m.sent_at,
          guid: m.guid,
          source: m.source,
          sender: m.sender_handle,
          chat: m.chat_key,
          style: m.chat_style,
          title: m.chat_display_name,
          from_user: m.is_from_me
        }

    observations =
      from o in Observation,
        where: o.user_id == ^user_id and o.occurred_at >= ^since and o.occurred_at <= ^now,
        where: o.source in ["gmail", "slack", "google_calendar"],
        select: %{
          id: o.id,
          at: o.occurred_at,
          source: o.source,
          item: o.source_item_id,
          account: o.source_account,
          from_user: o.direction == "outbound",
          participants: o.participants,
          title: fragment("left(?, 200)", o.subject),
          metadata:
            fragment(
              "jsonb_build_object('thread_id', ?->'thread_id', 'channel', ?->'channel', 'team_id', ?->'team_id', 'thread_ts', ?->'thread_ts', 'ts', ?->'ts', 'event_type', ?->'event_type', 'status', ?->'status', 'attendee_count', ?->'attendee_count')",
              o.metadata,
              o.metadata,
              o.metadata,
              o.metadata,
              o.metadata,
              o.metadata,
              o.metadata,
              o.metadata
            )
        }

    calendar =
      from e in LocalEvent,
        where: e.user_id == ^user_id and e.start_at >= ^since and e.start_at <= ^horizon,
        where: e.is_all_day == false,
        select: %{
          id: e.id,
          at: e.start_at,
          end_at: e.end_at,
          guid: e.guid,
          title: e.title,
          organizer: e.organizer_email,
          attendees: e.attendee_emails,
          attendee_count: e.attendees_count,
          encrypted: e.encrypted_with_device_key
        }

    acc = pages(messages, :sent_at, nil, acc, &reducer.(message(&1), &2), deadline)
    acc = pages(observations, :occurred_at, nil, acc, &reducer.(observation(&1), &2), deadline)
    pages(calendar, :start_at, nil, acc, &reducer.(calendar(&1, now), &2), deadline)
  end

  defp pages(query, field_name, cursor, acc, reducer, deadline) do
    if System.monotonic_time(:millisecond) > deadline, do: throw(:people_network_budget_exceeded)

    page =
      query
      |> after_cursor(field_name, cursor)
      |> order_by([r], asc: field(r, ^field_name), asc: r.id)
      |> limit(@page_size)
      |> ReadRepo.all()

    result = Enum.reduce(page, acc, reducer)

    if length(page) < @page_size do
      result
    else
      last = List.last(page)
      pages(query, field_name, {last.at, last.id}, result, reducer, deadline)
    end
  end

  defp after_cursor(query, _field, nil), do: query

  defp after_cursor(query, field_name, {at, id}) do
    where(
      query,
      [r],
      field(r, ^field_name) > ^at or (field(r, ^field_name) == ^at and r.id > ^id)
    )
  end

  defp message(row) do
    direct = row.style != "group" and not is_nil(Identity.normalize(row.chat))
    handle = if row.from_user and direct, do: row.chat, else: row.sender
    participants = if row.from_user and not direct, do: [], else: [contact(handle)]
    day = DateTime.to_date(row.at)

    %{
      key: "message:#{row.source}:#{row.guid || row.id}",
      at: row.at,
      source: row.source || "imessage",
      kind: if(direct, do: "direct", else: "shared"),
      from_user: row.from_user,
      participants: participants,
      context: "message:#{row.source}:#{row.chat || row.id}:#{day}",
      evidence: %{
        type: "message",
        id: row.id,
        title: row.title,
        at: iso(row.at),
        source: row.source || "imessage"
      }
    }
  end

  defp observation(%{source: "google_calendar"} = row) do
    metadata = row.metadata || %{}

    if metadata["status"] != "cancelled" do
      key = "google_calendar:#{row.account}:#{row.item}"

      %{
        key: key,
        at: row.at,
        source: "calendar",
        kind: "calendar",
        from_user: false,
        participants: Enum.map(row.participants || [], &Identity.participant/1),
        context: key,
        large?: (metadata["attendee_count"] || 0) > 10,
        evidence: %{
          type: "observation",
          id: row.id,
          title: row.title,
          at: iso(row.at),
          source: "calendar"
        }
      }
    end
  end

  defp observation(row) do
    metadata = row.metadata || %{}
    participants = Enum.map(row.participants || [], &Identity.participant/1)
    channel = metadata["channel"] || row.item
    day = DateTime.to_date(row.at)
    dm = is_binary(channel) and String.starts_with?(channel, "D")

    context =
      if row.source == "slack" do
        "slack:#{metadata["team_id"] || row.account}:#{channel}:#{metadata["thread_ts"] || "main"}:#{day}"
      else
        "gmail:#{row.account}:#{metadata["thread_id"] || row.item}:#{day}"
      end

    mutation =
      row.source == "slack" and
        (String.contains?(row.item, ":mutation:") or
           metadata["event_type"] in ["message_deleted", "message_changed"])

    automated =
      Enum.any?(participants, fn p ->
        p.role == "from" and is_binary(p.handle) and
          Regex.match?(~r/^(no[._-]?reply|do[._-]?not[._-]?reply|mailer-daemon)@/i, p.handle)
      end)

    if mutation or automated do
      nil
    else
      %{
        key: "observation:#{row.source}:#{row.item}",
        at: row.at,
        source: row.source,
        kind: if(row.source == "gmail" or dm, do: "candidate_direct", else: "shared"),
        from_user: row.from_user,
        participants: participants,
        context: context,
        peer_key:
          if(row.source == "slack" and dm,
            do: "slack:#{metadata["team_id"] || row.account}:#{channel}"
          ),
        evidence: %{
          type: "observation",
          id: row.id,
          title: row.title,
          at: iso(row.at),
          source: row.source
        }
      }
    end
  end

  defp calendar(row, now) do
    future = DateTime.compare(row.at, now) == :gt
    finished = is_nil(row.end_at) or DateTime.compare(row.end_at, now) != :gt
    participants = [row.organizer | List.wrap(row.attendees)] |> Enum.map(&contact/1)

    if future or finished do
      key = "calendar:#{row.guid || row.id}:#{iso(row.at)}"

      %{
        key: key,
        at: row.at,
        source: "calendar",
        kind: if(future, do: "upcoming", else: "calendar"),
        from_user: false,
        participants: participants,
        context: key,
        large?: max(row.attendee_count || 0, length(participants)) > 10,
        evidence: %{
          type: "calendar",
          id: row.id,
          title: if(row.encrypted, do: nil, else: row.title),
          at: iso(row.at),
          source: "calendar"
        }
      }
    end
  end

  defp contact(handle), do: %{handle: Identity.normalize(handle), name: nil, role: nil}
  defp iso(value), do: DateTime.to_iso8601(value)
end
