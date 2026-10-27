defmodule Maraithon.Crm.FiberEnrichment do
  @moduledoc "On-demand, user-scoped professional context for todo preparation."
  import Ecto.Query
  alias Maraithon.{Crm, Fiber, Repo}
  alias Maraithon.Crm.Person

  def ensure(user_id, person_id) do
    with %Person{status: "active"} = person <- Crm.get_person_for_user(user_id, person_id) do
      cached = (person.metadata || %{})["fiber"] || %{}

      cond do
        fresh?(cached) -> cached
        not Fiber.configured?() -> cached
        true -> lookup(person, cached)
      end
    else
      _ -> %{}
    end
  end

  defp lookup(person, cached) do
    details = person.contact_details || %{}

    email =
      [details["email"] | List.wrap(details["emails"])]
      |> Enum.find(&(is_binary(&1) and String.contains?(&1, "@")))

    case email && Fiber.reverse_email_lookup(email) do
      {:ok, %{profile: profile, credits: credits}} ->
        fiber = %{
          "status" => if(is_map(profile), do: "enriched", else: "no_match"),
          "attempted_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "profile" => compact_profile(profile),
          "credits_charged" => credits,
          "source_email" => email
        }

        store(person, fiber)

      {:error, _} ->
        store(
          person,
          Map.merge(cached, %{
            "status" => "error",
            "attempted_at" => DateTime.to_iso8601(DateTime.utc_now())
          })
        )

      _ ->
        cached
    end
  end

  defp store(person, fiber) do
    # Merge with the latest metadata after the network read. Never replace
    # user notes, contact identifiers, names, or relationship descriptions.
    Repo.transaction(fn ->
      current =
        Repo.one(
          from p in Person,
            where: p.id == ^person.id and p.user_id == ^person.user_id and p.status == "active",
            lock: "FOR UPDATE"
        )

      if current do
        current
        |> Person.changeset(%{metadata: Map.put(current.metadata || %{}, "fiber", fiber)})
        |> Repo.update!()
      end
    end)

    fiber
  end

  defp fresh?(fiber) do
    days =
      case fiber["status"] do
        "enriched" -> 90
        "no_match" -> 60
        _ -> 1
      end

    with at when is_binary(at) <- fiber["attempted_at"] || fiber["enriched_at"],
         {:ok, time, _} <- DateTime.from_iso8601(at) do
      DateTime.diff(DateTime.utc_now(), time, :second) in 0..(days * 86_400)
    else
      _ -> false
    end
  end

  defp compact_profile(%{} = profile) do
    %{
      "name" => text(profile["name"]),
      "headline" => text(profile["headline"]),
      "summary" => text(profile["summary"]),
      "linkedin_url" => text(profile["url"] || profile["linkedin_url"]),
      "experiences" =>
        profile["experiences"]
        |> List.wrap()
        |> Enum.filter(&is_map/1)
        |> Enum.take(3)
        |> Enum.map(&Map.take(&1, ~w(title company_name is_current start_date end_date)))
    }
  end

  defp compact_profile(_), do: nil
  defp text(value) when is_binary(value), do: String.slice(value, 0, 800)
  defp text(_), do: nil
end
