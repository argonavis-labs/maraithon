defmodule Maraithon.Travel.BriefRendererTest do
  use ExUnit.Case, async: true

  alias Maraithon.Travel.{BriefRenderer, Itinerary, ItineraryItem}

  test "renders cancelled travel updates with the affected reservations" do
    rendered =
      itinerary([
        %ItineraryItem{
          item_type: "flight",
          status: "cancelled",
          title: "Air Canada AC 123",
          location_label: "Toronto YYZ -> Austin AUS",
          confirmation_code: "ABC123",
          metadata: %{"display_date" => "Mar 15, 2026 at 2:00 PM"}
        },
        %ItineraryItem{
          item_type: "hotel",
          status: "cancelled",
          title: "Austin Marriott Downtown",
          location_label: "Austin",
          confirmation_code: "H98765",
          metadata: %{
            "display_check_in" => "Mar 15, 2026",
            "display_check_out" => "Mar 17, 2026"
          }
        }
      ])
      |> BriefRenderer.render(:travel_update,
        timezone_offset_hours: -5,
        reference_now: ~U[2026-03-14 22:00:00Z]
      )

    assert rendered.title == "Travel update: Austin"
    assert rendered.summary == "Travel reservations for Austin now appear cancelled."
    assert rendered.body =~ "Travel change: 2 reservations now appear cancelled."
    assert rendered.body =~ "CANCELLED RESERVATIONS"
    assert rendered.body =~ "Flight: Air Canada AC 123"
    assert rendered.body =~ "Booking Ref: ABC123"
    assert rendered.body =~ "Hotel: Austin Marriott Downtown"
    assert rendered.body =~ "Itinerary #: H98765"
    refute rendered.body =~ "I detected"
    refute rendered.body =~ "I found"
  end

  test "renders partial cancellation updates alongside the current itinerary" do
    rendered =
      itinerary([
        %ItineraryItem{
          item_type: "flight",
          status: "cancelled",
          title: "Air Canada AC 123",
          location_label: "Toronto YYZ -> Austin AUS",
          confirmation_code: "ABC123",
          metadata: %{"display_date" => "Mar 15, 2026 at 2:00 PM"}
        },
        %ItineraryItem{
          item_type: "hotel",
          status: "updated",
          title: "Austin Marriott Downtown",
          location_label: "Austin",
          confirmation_code: "H98765",
          metadata: %{
            "address" => "304 East Cesar Chavez St, Austin, TX 78701",
            "display_check_in" => "Mar 15, 2026",
            "display_check_out" => "Mar 18, 2026",
            "room" => "Suite 1108"
          }
        }
      ])
      |> BriefRenderer.render(:travel_update,
        timezone_offset_hours: -5,
        reference_now: ~U[2026-03-14 22:00:00Z]
      )

    assert rendered.summary == "Updated itinerary for Austin with one cancelled reservation."
    assert rendered.body =~ "Travel change: one reservation now appears cancelled."
    assert rendered.body =~ "HOTEL"
    assert rendered.body =~ "Check-out: Mar 18, 2026"
    assert rendered.body =~ "CANCELLED RESERVATION"
    assert rendered.body =~ "Flight: Air Canada AC 123"
  end

  test "adds chief-of-staff checks and next move for incomplete travel details" do
    rendered =
      itinerary([
        %ItineraryItem{
          item_type: "flight",
          status: "active",
          title: "Air Canada AC 123",
          location_label: "Toronto YYZ -> Austin AUS",
          confirmation_code: nil,
          metadata: %{"display_date" => "Mar 15, 2026 at 2:00 PM"}
        }
      ])
      |> BriefRenderer.render(:travel_prep,
        timezone_offset_hours: -5,
        reference_now: ~U[2026-03-14 22:00:00Z]
      )

    assert rendered.summary == "Ready flight details for Austin."
    assert rendered.body =~ "CHECK BEFORE YOU GO"
    assert rendered.body =~ "No hotel confirmation found for Austin"
    assert rendered.body =~ "Air Canada AC 123 is missing a booking reference"
    assert rendered.body =~ "NEXT MOVE"
    assert rendered.body =~ "Confirm lodging for Austin"
    refute rendered.body =~ "I detected"
    refute rendered.body =~ "I found"
  end

  test "keeps complete travel briefs action-oriented without inventing missing work" do
    rendered =
      itinerary([
        %ItineraryItem{
          item_type: "flight",
          status: "active",
          title: "Air Canada AC 123",
          location_label: "Toronto YYZ -> Austin AUS",
          confirmation_code: "ABC123",
          metadata: %{"display_date" => "Mar 15, 2026 at 2:00 PM"}
        },
        %ItineraryItem{
          item_type: "hotel",
          status: "active",
          title: "Austin Marriott Downtown",
          location_label: "Austin",
          confirmation_code: "H98765",
          metadata: %{
            "address" => "304 East Cesar Chavez St, Austin, TX 78701",
            "display_check_in" => "Mar 15, 2026",
            "display_check_out" => "Mar 17, 2026"
          }
        }
      ])
      |> BriefRenderer.render(:travel_prep,
        timezone_offset_hours: -5,
        reference_now: ~U[2026-03-14 22:00:00Z]
      )

    refute rendered.body =~ "CHECK BEFORE YOU GO"
    assert rendered.body =~ "NEXT MOVE"
    assert rendered.body =~ "Save the flight time, hotel address, and confirmation codes"
    refute rendered.body =~ "No hotel confirmation found"
    refute rendered.body =~ "No active flight confirmation found"
  end

  defp itinerary(items) do
    %Itinerary{
      title: "Travel to Austin",
      status: "changed_after_send",
      destination_label: "Austin",
      starts_at: ~U[2026-03-15 19:00:00Z],
      items: items
    }
  end
end
