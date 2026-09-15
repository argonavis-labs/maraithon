defmodule Maraithon.AccountCategories do
  @moduledoc "User-selected account categories, independent of provider token refreshes."
  import Ecto.Query
  alias Maraithon.{Accounts.ConnectedAccount, ConnectedAccounts, Repo}

  def list(user_id) do
    ConnectedAccounts.list_personal_for_user(user_id)
    |> Enum.map(
      &%{
        id: &1.id,
        label: &1.external_account_id || &1.provider,
        provider: &1.provider,
        category: &1.category
      }
    )
  end

  def index(user_id), do: Map.new(list(user_id), &{&1.id, &1.category})

  def update(user_id, account_id, category) when category in ~w(unassigned personal work) do
    Repo.transaction(fn ->
      Maraithon.DurablePayload.require_current_mutation!()
      Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(user_id)

      account =
        Maraithon.AssistantIdentities.user_accounts()
        |> where([a], a.user_id == ^user_id and a.id == ^account_id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      if account do
        account |> Ecto.Changeset.change(category: category) |> Repo.update!()
      else
        Repo.rollback(:not_found)
      end
    end)
  end

  def update(_, _, _), do: {:error, :invalid_category}

  def filter(query, user_id, category) when category in ~w(personal work) do
    accounts =
      from a in ConnectedAccount,
        where: a.user_id == ^user_id and a.category == ^category,
        select: a.id

    where(query, [todo], todo.source_account_id in subquery(accounts))
  end

  def filter(query, _, _), do: query

  def for_todo(todo, index \\ nil),
    do: Map.get(index || index(todo.user_id), todo.source_account_id, "unassigned")
end
