defmodule Maraithon.Tools.ListPeople do
  @moduledoc """
  List CRM people for a user.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.Crm
  alias Maraithon.Tools.PersonHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id") do
      people = Crm.list_people(user_id, PersonHelpers.people_list_opts(args))

      {:ok,
       %{
         source: "maraithon_crm",
         count: length(people),
         people: Enum.map(people, &PersonHelpers.serialize_person/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
