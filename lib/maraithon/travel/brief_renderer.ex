defmodule Maraithon.Travel.BriefRenderer do
  @moduledoc """
  Renders Telegram-ready travel prep and update briefs.
  """

  def render(itinerary, mode, opts \\ []) when is_map(itinerary) do
    offset_hours = Keyword.get(opts, :timezone_offset_hours, -5)
    reference_now = Keyword.get(opts, :reference_now)
    items = sort_items(Map.get(itinerary, :items) || Map.get(itinerary, "items") || [])
    visible_items = Enum.reject(items, &(&1.status == "superseded"))
    cancelled_items = Enum.filter(visible_items, &(&1.status == "cancelled"))
    trip_date = local_trip_date(itinerary, offset_hours)
    prep_day_label = prep_day_label(itinerary, offset_hours, reference_now)

    title_prefix =
      if mode == :travel_update, do: "Travel update", else: "Travel #{prep_day_label}"

    destination = itinerary.destination_label || "your trip"

    intro =
      case {mode, cancelled_items} do
        {:travel_update, [_ | _]} ->
          "Travel change: #{cancelled_intro(cancelled_items)} Review before relying on this trip:"

        {:travel_update, []} ->
          "Travel details changed. Current itinerary:"

        _ ->
          "Here are your travel details for #{prep_day_label} (#{trip_date}):"
      end

    sections =
      [
        render_flight_section(visible_items),
        render_hotel_section(visible_items),
        render_cancelled_section(cancelled_items),
        render_check_before_you_go_section(visible_items, destination),
        render_next_move_section(visible_items, destination)
      ]
      |> Enum.reject(&is_nil/1)

    body =
      ([intro] ++ sections)
      |> Enum.join("\n\n")
      |> String.trim()

    snapshot = digest_snapshot(itinerary, visible_items, trip_date, destination)

    %{
      title: "#{title_prefix}: #{destination}",
      summary: summary_line(visible_items, destination, mode),
      body: body,
      digest_hash: digest_hash(snapshot),
      local_trip_date: trip_date
    }
  end

  def digest_hash(snapshot) when is_map(snapshot) do
    snapshot
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp render_flight_section(items) do
    flights =
      items
      |> Enum.filter(&(&1.item_type == "flight"))
      |> Enum.reject(&(&1.status == "cancelled"))

    case flights do
      [] ->
        nil

      flights ->
        lines =
          flights
          |> Enum.flat_map(fn flight ->
            [
              "FLIGHT",
              flight.title || flight.vendor_name || "Flight",
              flight.location_label,
              get_in(flight.metadata || %{}, ["display_date"]),
              confirmation_line(flight.confirmation_code, "Booking Ref")
            ]
            |> Enum.reject(&blank?/1)
          end)

        Enum.join(lines, "\n")
    end
  end

  defp render_hotel_section(items) do
    hotels =
      items
      |> Enum.filter(&(&1.item_type == "hotel"))
      |> Enum.reject(&(&1.status == "cancelled"))

    case hotels do
      [] ->
        nil

      hotels ->
        lines =
          hotels
          |> Enum.flat_map(fn hotel ->
            metadata = hotel.metadata || %{}

            [
              "HOTEL",
              hotel.title || hotel.vendor_name || "Hotel",
              metadata["address"],
              prefixed_line("Check-in", metadata["display_check_in"]),
              prefixed_line("Check-out", metadata["display_check_out"]),
              prefixed_line("Room", metadata["room"]),
              confirmation_line(hotel.confirmation_code, "Itinerary #"),
              prefixed_line("Hotel Phone", metadata["hotel_phone"])
            ]
            |> Enum.reject(&blank?/1)
          end)

        Enum.join(lines, "\n")
    end
  end

  defp render_cancelled_section([]), do: nil

  defp render_cancelled_section(items) do
    heading =
      if length(items) == 1 do
        "CANCELLED RESERVATION"
      else
        "CANCELLED RESERVATIONS"
      end

    lines =
      items
      |> Enum.flat_map(&cancelled_item_lines/1)

    Enum.join([heading | lines], "\n")
  end

  defp render_check_before_you_go_section(items, destination) do
    bullets = missing_detail_bullets(items, destination)

    case bullets do
      [] -> nil
      _ -> Enum.join(["CHECK BEFORE YOU GO" | bullets], "\n")
    end
  end

  defp render_next_move_section(items, destination) do
    "NEXT MOVE\n#{next_move_line(items, destination)}"
  end

  defp missing_detail_bullets(items, destination) do
    active_flights = active_items(items, "flight")
    active_hotels = active_items(items, "hotel")
    active_count = length(active_flights) + length(active_hotels)
    cancelled_count = Enum.count(items, &(&1.status == "cancelled"))

    []
    |> maybe_add(active_flights != [] and active_hotels == [], fn ->
      "- No hotel confirmation found for #{destination_phrase(destination)}; confirm lodging before departure."
    end)
    |> maybe_add(active_hotels != [] and active_flights == [], fn ->
      "- No active flight confirmation found for #{destination_phrase(destination)}; confirm transportation before relying on the hotel reservation."
    end)
    |> maybe_add(active_count == 0 and cancelled_count > 0, fn ->
      "- All known reservations are cancelled; confirm whether the trip is still happening before relying on old details."
    end)
    |> Kernel.++(missing_flight_bullets(active_flights))
    |> Kernel.++(missing_hotel_bullets(active_hotels))
  end

  defp missing_flight_bullets(flights) do
    Enum.flat_map(flights, fn flight ->
      [
        missing_bullet(
          blank?(flight.confirmation_code),
          "#{item_name(flight, "Flight")} is missing a booking reference; keep the carrier email handy."
        ),
        missing_bullet(
          blank?(get_in(flight.metadata || %{}, ["display_date"])),
          "#{item_name(flight, "Flight")} is missing a readable departure time; verify the departure window before leaving."
        )
      ]
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp missing_hotel_bullets(hotels) do
    Enum.flat_map(hotels, fn hotel ->
      [
        missing_bullet(
          blank?(get_in(hotel.metadata || %{}, ["address"])),
          "#{item_name(hotel, "Hotel")} is missing the street address; open the reservation before heading there."
        ),
        missing_bullet(
          blank?(hotel.confirmation_code),
          "#{item_name(hotel, "Hotel")} is missing a confirmation number; keep the booking email handy at check-in."
        )
      ]
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp next_move_line(items, destination) do
    active_flights = active_items(items, "flight")
    active_hotels = active_items(items, "hotel")
    active_count = length(active_flights) + length(active_hotels)
    cancelled_count = Enum.count(items, &(&1.status == "cancelled"))

    missing_detail_count =
      length(missing_flight_bullets(active_flights) ++ missing_hotel_bullets(active_hotels))

    cond do
      active_count == 0 and cancelled_count > 0 ->
        "Confirm whether the trip is still happening and look for replacement reservations before you travel."

      active_flights != [] and active_hotels == [] ->
        "Confirm lodging for #{destination_phrase(destination)}, then save the flight details somewhere reachable offline."

      active_hotels != [] and active_flights == [] ->
        "Confirm transportation to #{destination_phrase(destination)}, then save the hotel address and confirmation."

      missing_detail_count > 0 ->
        "Open the carrier and hotel emails now, fill the missing confirmation details, and save the itinerary offline."

      true ->
        "Save the flight time, hotel address, and confirmation codes somewhere reachable offline."
    end
  end

  defp active_items(items, item_type) do
    Enum.filter(items, &(&1.item_type == item_type and &1.status != "cancelled"))
  end

  defp missing_bullet(true, text), do: "- #{text}"
  defp missing_bullet(false, _text), do: nil

  defp maybe_add(list, true, callback), do: list ++ [callback.()]
  defp maybe_add(list, false, _callback), do: list

  defp item_name(item, fallback) do
    item.title || item.vendor_name || fallback
  end

  defp destination_phrase("your trip"), do: "this trip"
  defp destination_phrase(destination), do: destination

  defp cancelled_item_lines(item) do
    metadata = item.metadata || %{}

    [
      "#{reservation_type_label(item.item_type)}: #{item.title || item.vendor_name || "Reservation"}",
      item.location_label,
      get_in(metadata, ["display_date"]),
      prefixed_line("Check-in", metadata["display_check_in"]),
      prefixed_line("Check-out", metadata["display_check_out"]),
      confirmation_line(item.confirmation_code, confirmation_label(item.item_type))
    ]
    |> Enum.reject(&blank?/1)
  end

  defp local_trip_date(itinerary, offset_hours) do
    itinerary.starts_at
    |> Kernel.||(DateTime.utc_now())
    |> DateTime.add(offset_hours * 3600, :second)
    |> Calendar.strftime("%b %-d")
  end

  defp prep_day_label(itinerary, offset_hours, %DateTime{} = reference_now) do
    if trip_local_date(itinerary, offset_hours) == local_date(reference_now, offset_hours) do
      "today"
    else
      "tomorrow"
    end
  end

  defp prep_day_label(_itinerary, _offset_hours, _reference_now), do: "tomorrow"

  defp summary_line(items, destination, mode) do
    has_flight? = Enum.any?(items, &(&1.item_type == "flight" and &1.status != "cancelled"))
    has_hotel? = Enum.any?(items, &(&1.item_type == "hotel" and &1.status != "cancelled"))
    cancelled_count = Enum.count(items, &(&1.status == "cancelled"))

    prefix =
      case mode do
        :travel_update -> "Updated"
        _ -> "Ready"
      end

    cond do
      mode == :travel_update and cancelled_count > 0 and not has_flight? and not has_hotel? ->
        "Travel reservations for #{destination} now appear cancelled."

      mode == :travel_update and cancelled_count == 1 ->
        "Updated itinerary for #{destination} with one cancelled reservation."

      mode == :travel_update and cancelled_count > 1 ->
        "Updated itinerary for #{destination} with #{cancelled_count} cancelled reservations."

      has_flight? and has_hotel? ->
        "#{prefix} flight and hotel details for #{destination}."

      has_flight? ->
        "#{prefix} flight details for #{destination}."

      has_hotel? ->
        "#{prefix} hotel details for #{destination}."

      true ->
        "#{prefix} travel details for #{destination}."
    end
  end

  defp digest_snapshot(itinerary, items, trip_date, destination) do
    %{
      trip_date: trip_date,
      destination: destination,
      title: itinerary.title,
      status: itinerary.status,
      items:
        Enum.map(items, fn item ->
          %{
            item_type: item.item_type,
            status: item.status,
            title: item.title,
            location_label: item.location_label,
            starts_at: item.starts_at,
            ends_at: item.ends_at,
            confirmation_code: item.confirmation_code,
            metadata:
              Map.take(item.metadata || %{}, [
                "display_date",
                "display_check_in",
                "display_check_out",
                "address",
                "room",
                "hotel_phone"
              ])
          }
        end)
    }
  end

  defp sort_items(items) do
    Enum.sort_by(items, fn item ->
      type_rank =
        case item.item_type do
          "flight" -> 0
          "hotel" -> 1
          _ -> 2
        end

      {type_rank, item.starts_at || item.inserted_at}
    end)
  end

  defp cancelled_intro([_item]), do: "one reservation now appears cancelled."
  defp cancelled_intro(items), do: "#{length(items)} reservations now appear cancelled."

  defp reservation_type_label("flight"), do: "Flight"
  defp reservation_type_label("hotel"), do: "Hotel"
  defp reservation_type_label(_type), do: "Reservation"

  defp confirmation_label("hotel"), do: "Itinerary #"
  defp confirmation_label(_type), do: "Booking Ref"

  defp trip_local_date(itinerary, offset_hours) do
    itinerary.starts_at
    |> Kernel.||(DateTime.utc_now())
    |> local_date(offset_hours)
  end

  defp local_date(%DateTime{} = datetime, offset_hours) do
    datetime
    |> DateTime.add(offset_hours * 3600, :second)
    |> DateTime.to_date()
  end

  defp confirmation_line(nil, _label), do: nil
  defp confirmation_line("", _label), do: nil
  defp confirmation_line(value, label), do: "#{label}: #{value}"

  defp prefixed_line(_label, nil), do: nil
  defp prefixed_line(_label, ""), do: nil

  defp prefixed_line(label, value) do
    if String.starts_with?(String.downcase(value), String.downcase("#{label}:")) do
      value
    else
      "#{label}: #{value}"
    end
  end

  defp blank?(value) when value in [nil, ""], do: true
  defp blank?(_value), do: false
end
