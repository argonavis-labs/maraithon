defmodule Maraithon.RelationshipIntelligence.Sources do
  @moduledoc "Input provenance for personal learning, captured by the server rather than the model."
  import Ecto.Query
  alias Maraithon.{AssistantIdentities, ConnectedAccounts, Repo}
  alias Maraithon.Crm.Observation

  # Callers pass the same bounded observations used in the prompt. This records
  # input provenance, not proof that every generated claim follows from a source.
  def capture(user_id, observations) do
    ids =
      observations
      |> Enum.map(& &1["observation_id"])
      |> Enum.filter(&match?({:ok, _}, Ecto.UUID.cast(&1)))

    stored =
      from(o in Observation, where: o.user_id == ^user_id and o.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    accounts = ConnectedAccounts.list_for_user(user_id)
    assistants = MapSet.new(AssistantIdentities.assistant_account_ids(user_id))

    Enum.reduce_while(observations, {:ok, []}, fn input, {:ok, refs} ->
      case reference(input, stored, accounts, assistants) do
        {:ok, ref} -> {:cont, {:ok, [ref | refs]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, %{"version" => 1, "inputs" => Enum.reverse(refs)}}
      error -> error
    end
  end

  defp reference(input, stored, accounts, assistants) do
    id = input["observation_id"]
    observation = stored[id]
    source = if observation, do: Observation.to_intelligence_input(observation), else: input
    google? = source["source"] in ~w(gmail calendar google_calendar)
    hints = account_hints(source)

    matches =
      if google? do
        Enum.filter(accounts, fn account ->
          account.provider in ["google"] or String.starts_with?(account.provider, "google:")
        end)
        |> Enum.filter(fn account ->
          keys =
            [account.id, account.provider, account.external_account_id] ++
              Map.values(Map.take(account.metadata || %{}, ~w(account_email email)))

          Enum.any?(normalize(keys), &(&1 in hints))
        end)
      else
        []
      end

    cond do
      not is_nil(id) and is_nil(observation) ->
        {:error, :relationship_source_not_found}

      Enum.any?(matches, &MapSet.member?(assistants, &1.id)) ->
        {:error, :assistant_source_excluded}

      true ->
        {:ok,
         %{
           "observation_id" => observation && observation.id,
           "source" => source["source"],
           "source_item_id" => source["source_item_id"] || source["resource_id"],
           "connected_account_id" => if(length(matches) == 1, do: hd(matches).id),
           "binding" => if(observation, do: "stored_observation", else: "input")
         }}
    end
  end

  defp account_hints(input) do
    metadata = if is_map(input["metadata"]), do: input["metadata"], else: %{}

    normalize([
      input["source_account"],
      input["account"],
      input["connected_account_id"],
      metadata["connected_account_id"],
      metadata["google_provider"],
      metadata["account_email"]
    ])
  end

  defp normalize(values) do
    values
    |> Enum.filter(&(is_binary(&1) or is_integer(&1)))
    |> Enum.map(&(to_string(&1) |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end
end
