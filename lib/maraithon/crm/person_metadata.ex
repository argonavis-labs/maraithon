defmodule Maraithon.Crm.PersonMetadata do
  @moduledoc "Atomic background metadata patches that preserve newer People learning."
  import Ecto.Query
  alias Maraithon.{Crm.Person, Repo}

  @keys ~w(enrichment merge_suggestion communication_signals graph_signals)

  def patch(%Person{} = person, key, value, metrics \\ []) when key in @keys do
    metadata =
      if is_nil(value) do
        dynamic([p], fragment("COALESCE(?, '{}'::jsonb) - ?", p.metadata, type(^key, :string)))
      else
        patch = %{key => value}
        dynamic([p], fragment("COALESCE(?, '{}'::jsonb) || ?", p.metadata, type(^patch, :map)))
      end

    updates = [set: [metadata: metadata, updated_at: DateTime.utc_now()] ++ metrics]

    query =
      from p in Person,
        where: p.id == ^person.id and p.user_id == ^person.user_id,
        update: ^updates

    case Repo.update_all(query, []) do
      {1, _} -> {:ok, :updated}
      {0, _} -> {:error, :person_not_found}
    end
  end
end
