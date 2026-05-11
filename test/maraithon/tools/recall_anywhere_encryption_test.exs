defmodule Maraithon.Tools.RecallAnywhereEncryptionTest do
  @moduledoc """
  End-to-end coverage of the v4 encryption render rules through
  `recall_anywhere`: rows flagged `encrypted_with_device_key: true` come
  back with the `[encrypted_with_device_key]` placeholder for any content
  field, while metadata (timestamps, list/folder/path) is preserved. We
  install a stub source function that returns one synthetic, already-
  normalized hit so we can assert on the public dispatch behaviour
  without touching every source's substring search.
  """

  use ExUnit.Case, async: false

  alias Maraithon.Tools
  alias Maraithon.Tools.RecallAnywhereHelpers

  @app_key :recall_anywhere_sources
  @placeholder RecallAnywhereHelpers.encrypted_placeholder()

  setup do
    previous = Application.get_env(:maraithon, @app_key)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:maraithon, @app_key)
        value -> Application.put_env(:maraithon, @app_key, value)
      end
    end)

    :ok
  end

  test "placeholder is exposed as a public helper" do
    assert is_binary(@placeholder)
    assert @placeholder == "[encrypted_with_device_key]"
  end

  test "an encrypted-tagged hit flows through ranking unchanged" do
    encrypted_hit = %{
      source: "local_notes",
      id: "n1",
      title: @placeholder,
      snippet: @placeholder,
      timestamp: DateTime.utc_now(),
      match_field: :none
    }

    Application.put_env(:maraithon, @app_key, %{
      "local_notes" => fn _user, _query, _opts -> [encrypted_hit] end
    })

    assert {:ok, result} =
             Tools.execute("recall_anywhere", %{
               "user_id" => "user@example.com",
               "query" => "anything",
               "sources" => ["local_notes"]
             })

    assert [hit] = result.results
    assert hit.title == @placeholder
    assert hit.snippet == @placeholder
    assert hit.id == "n1"
  end

  test "non-encrypted hit renders without the placeholder" do
    plain_hit = %{
      source: "local_notes",
      id: "n2",
      title: "Meeting prep",
      snippet: "agenda ...",
      timestamp: DateTime.utc_now(),
      match_field: :title
    }

    Application.put_env(:maraithon, @app_key, %{
      "local_notes" => fn _user, _query, _opts -> [plain_hit] end
    })

    assert {:ok, result} =
             Tools.execute("recall_anywhere", %{
               "user_id" => "user@example.com",
               "query" => "agenda",
               "sources" => ["local_notes"]
             })

    assert [hit] = result.results
    refute hit.title == @placeholder
    refute hit.snippet == @placeholder
  end
end
