defmodule Maraithon.UserIdentity do
  @moduledoc """
  Canonical answer to "who is the user?" across every channel.

  The user shows up in connected data under many handles — their account
  email, OAuth account emails, the phone numbers and Apple IDs their own
  iMessages send from, and the names and handles they explicitly confirmed.
  Conversation-reading intelligence (todo detectors, chief-of-staff skills,
  the assistant context, relationship learning) must know all of them, or a
  group chat where the user already answered reads like someone asking the
  user for something.

  Identity is assembled from durable evidence, cached briefly, and exposed
  both as structured data and as a compact prompt block.
  """

  use GenServer

  alias Maraithon.Repo
  alias Maraithon.UserIdentity.Profile

  @table __MODULE__
  @cache_ttl_ms :timer.minutes(15)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_args) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Returns the user's identity:

      %{
        emails: ["kent@runner.now", ...],
        phones: ["4167881373", ...],
        names: ["Kent Fenwick", ...],
        handles: MapSet (normalized emails + phones)
      }
  """
  def identity(user_id) when is_binary(user_id) do
    case cached(user_id) do
      nil ->
        identity = build(user_id)
        cache(user_id, identity)
        identity

      identity ->
        identity
    end
  end

  def identity(_user_id), do: empty()

  @doc "Normalized set of every handle that is the user."
  def handle_set(user_id), do: identity(user_id).handles

  @doc "Whether a raw email/phone/handle belongs to the user."
  def own_handle?(user_id, value) do
    case normalize_handle(value) do
      nil -> false
      handle -> MapSet.member?(handle_set(user_id), handle)
    end
  end

  @doc """
  Compact prompt block stating who the user is, for any model call that
  interprets conversations. Always includes the rule that the user's own
  messages are the user speaking.
  """
  def prompt_block(user_id) do
    identity = identity(user_id)

    name =
      case identity.names do
        [name | _] -> name
        _ -> user_id
      end

    handles =
      [
        describe_list("emails", identity.emails),
        describe_list("phone numbers", Enum.map(identity.phones, &format_phone/1))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("; ")

    """
    USER IDENTITY: The user is #{name} (#{user_id}).#{if handles != "", do: " Their own #{handles}."}
    Messages sent from any of the user's own handles (or marked from_user/is_from_me) are the USER speaking — never treat them as someone contacting or asking the user. In group conversations, only treat something as a request for the user when it is directed AT the user; channel membership alone is not responsibility. Implicit responsibility requires source evidence or an explicit user instruction connecting the user to the outcome. A user commitment remains open until fulfilled; an answered question or resolved request is handled.
    """
    |> String.trim()
  end

  @doc "Drops the cached identity (e.g. after contact syncs)."
  def invalidate(user_id) when is_binary(user_id) do
    :ets.delete(@table, user_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def invalidate(_user_id), do: :ok

  # ---------------------------------------------------------------------------
  # Confirmed profile (onboarding)
  # ---------------------------------------------------------------------------

  @doc "The stored profile, or nil."
  def profile(user_id) when is_binary(user_id), do: Repo.get(Profile, user_id)
  def profile(_user_id), do: nil

  @doc "Whether the user has confirmed their identity details."
  def confirmed?(user_id) do
    case profile(user_id) do
      %Profile{confirmed_at: %DateTime{}} -> true
      _ -> false
    end
  end

  @doc """
  Saves the user-confirmed identity. Handles are normalized; emails and
  phones the user removes stay out of the confirmed set (derived evidence
  still supplements at read time).
  """
  def confirm(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    emails =
      attrs |> read_list(:emails) |> Enum.map(&normalize_handle/1) |> clean_handles(&email?/1)

    phones =
      attrs
      |> read_list(:phones)
      |> Enum.map(&normalize_handle/1)
      |> clean_handles(&(not email?(&1)))

    display_name =
      case attrs[:display_name] || attrs["display_name"] do
        name when is_binary(name) -> name |> String.trim() |> presence()
        _ -> nil
      end

    result =
      (profile(user_id) || %Profile{user_id: user_id})
      |> Profile.changeset(%{
        user_id: user_id,
        display_name: display_name,
        emails: emails,
        phones: phones,
        confirmed_at: DateTime.utc_now()
      })
      |> Repo.insert_or_update()

    invalidate(user_id)
    result
  end

  @doc """
  Prefill for the onboarding form: everything already derivable from
  connected accounts and the user's own messages.
  """
  def onboarding_prefill(user_id) do
    invalidate(user_id)
    identity = identity(user_id)

    %{
      display_name: List.first(identity.names) || name_from_email(user_id),
      emails: identity.emails,
      phones: Enum.map(identity.phones, &format_phone/1)
    }
  end

  defp read_list(attrs, key) do
    (attrs[key] || attrs[to_string(key)] || [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp clean_handles(values, keep) do
    values
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(keep)
    |> Enum.uniq()
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  defp name_from_email(user_id) do
    user_id
    |> String.split("@")
    |> List.first()
    |> String.replace(~r/[._-]+/, " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
    |> presence()
  end

  # ---------------------------------------------------------------------------
  # Assembly
  # ---------------------------------------------------------------------------

  # Seeds must be handles that are unambiguously the user: their account
  # email, OAuth account emails, and anything they explicitly confirmed.
  # (iMessage sender_handle on is_from_me rows is the counterparty, NOT the
  # user — learned the hard way; never seed identity from it.)
  defp build(user_id) do
    profile = safe_profile(user_id)

    confirmed_handles =
      ((profile && profile.emails ++ profile.phones) || [])
      |> Enum.map(&normalize_handle/1)
      |> Enum.reject(&is_nil/1)

    seed_emails =
      [user_id | oauth_emails(user_id)]
      |> Enum.map(&normalize_handle/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&email?/1)

    seeds = MapSet.new(confirmed_handles ++ seed_emails)

    all = seeds

    names =
      [(profile && profile.display_name) || name_from_email(user_id)]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    %{
      emails: all |> Enum.filter(&email?/1) |> Enum.sort(),
      phones: all |> Enum.reject(&email?/1) |> Enum.sort(),
      names: names,
      handles: all
    }
  end

  defp safe_profile(user_id) do
    profile(user_id)
  rescue
    _ -> nil
  end

  defp oauth_emails(user_id) do
    user_id
    |> Maraithon.OAuth.list_user_tokens()
    |> Enum.flat_map(fn token ->
      [
        provider_email(token.provider),
        get_in(token.metadata || %{}, ["email"]),
        get_in(token.metadata || %{}, ["account_email"]),
        get_in(token.metadata || %{}, ["google_account_email"])
      ]
    end)
    |> Enum.filter(&is_binary/1)
  rescue
    _ -> []
  end

  defp provider_email("google:" <> email), do: email
  defp provider_email(_provider), do: nil

  # CRM enrichment may associate unrelated handles with a contact. Those
  # associations never expand authenticated or explicitly confirmed identity.

  # ---------------------------------------------------------------------------
  # Normalization (shared semantics with Crm.CommunicationScore)
  # ---------------------------------------------------------------------------

  @doc "Normalizes an email or phone to its comparable form, or nil."
  def normalize_handle(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      String.contains?(value, "@") ->
        case Regex.run(~r/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i, value) do
          [email] -> String.downcase(email)
          _ -> nil
        end

      true ->
        digits = String.replace(value, ~r/[^0-9]/, "")

        cond do
          String.length(digits) >= 10 -> String.slice(digits, -10, 10)
          String.length(digits) >= 7 -> digits
          true -> nil
        end
    end
  end

  def normalize_handle(_value), do: nil

  defp email?(handle), do: String.contains?(handle, "@")

  defp format_phone(digits) when byte_size(digits) == 10 do
    "#{String.slice(digits, 0, 3)}-#{String.slice(digits, 3, 3)}-#{String.slice(digits, 6, 4)}"
  end

  defp format_phone(digits), do: digits

  defp describe_list(_label, []), do: nil
  defp describe_list(label, values), do: "#{label}: #{Enum.join(values, ", ")}"

  # ---------------------------------------------------------------------------
  # Cache
  # ---------------------------------------------------------------------------

  defp cached(user_id) do
    case :ets.lookup(@table, user_id) do
      [{^user_id, identity, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at, do: identity

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  defp cache(user_id, identity) do
    expires_at = System.monotonic_time(:millisecond) + @cache_ttl_ms
    :ets.insert(@table, {user_id, identity, expires_at})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp empty do
    %{emails: [], phones: [], names: [], handles: MapSet.new()}
  end
end
