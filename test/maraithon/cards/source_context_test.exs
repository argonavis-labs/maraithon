defmodule Maraithon.Cards.SourceContextTest do
  use ExUnit.Case, async: true

  alias Maraithon.Cards.SourceContext

  test "preserves from/to/cc/bcc participants from mixed headers" do
    context =
      SourceContext.for_todo(%{
        "source" => "gmail",
        "metadata" => %{
          "from" => "Pedro Alvarez <pedro@acme.com>",
          "to" => "kent@runner.now, Dana Chen <dana@acme.com>",
          "cc" => "ops@acme.com; Lee Wong <lee@acme.com>",
          "bcc" => "archive@runner.now"
        }
      })

    participants = context["participants"]

    assert %{"role" => "from", "name" => "Pedro Alvarez", "handle" => "pedro@acme.com"} in participants

    roles = Enum.frequencies_by(participants, & &1["role"])
    assert roles["to"] == 2
    assert roles["cc"] == 2
    assert roles["bcc"] == 1

    handles = participants |> Enum.map(& &1["handle"]) |> Enum.sort()

    assert handles == [
             "archive@runner.now",
             "dana@acme.com",
             "kent@runner.now",
             "lee@acme.com",
             "ops@acme.com",
             "pedro@acme.com"
           ]
  end

  test "includes crm people once even when also a role participant" do
    context =
      SourceContext.for_todo(%{
        "source" => "gmail",
        "metadata" => %{
          "from" => "Pedro Alvarez <pedro@acme.com>",
          "person" => "Pedro Alvarez",
          "crm_people" => [
            %{"display_name" => "Pedro Alvarez", "contact_details" => %{"email" => "pedro@acme.com"}},
            %{"display_name" => "Sam Hill", "contact_details" => %{"email" => "sam@hill.co"}}
          ]
        }
      })

    participants = context["participants"]

    pedro_entries = Enum.filter(participants, &(&1["handle"] == "pedro@acme.com"))
    assert length(pedro_entries) == 1
    assert hd(pedro_entries)["role"] == "from"

    assert Enum.any?(participants, &(&1["handle"] == "sam@hill.co" and &1["role"] == "participant"))
  end

  test "builds a conversation excerpt with the sender as speaker" do
    context =
      SourceContext.for_todo(%{
        "source" => "gmail",
        "metadata" => %{
          "from" => "Pedro Alvarez <pedro@acme.com>",
          "body_excerpt" => "Can you confirm the Q3 numbers before Friday?"
        }
      })

    assert [%{"speaker" => "Pedro Alvarez", "text" => "Can you confirm the Q3 numbers before Friday?"}] =
             context["conversation"]
  end

  test "rejects technical excerpts and unparseable handles" do
    context =
      SourceContext.for_todo(%{
        "source" => "gmail",
        "metadata" => %{
          "from" => "token=secret",
          "body_excerpt" => "Authorization: Bearer abc stacktrace"
        }
      })

    assert context["participants"] in [nil, []]
    assert context["conversation"] in [nil, []]
  end

  test "for_payload extracts participants from prepared action payloads" do
    context =
      SourceContext.for_payload(%{
        "from" => "kent@runner.now",
        "to" => "Pedro Alvarez <pedro@acme.com>",
        "cc" => "dana@acme.com",
        "subject" => "Q3"
      })

    roles = Enum.map(context["participants"], & &1["role"])
    assert "from" in roles and "to" in roles and "cc" in roles
  end

  test "merge_into does not overwrite existing card fields" do
    card = %{"participants" => [:existing]}
    merged = SourceContext.merge_into(card, %{"participants" => [:new], "conversation" => [:c]})

    assert merged["participants"] == [:existing]
    assert merged["conversation"] == [:c]
  end
end
