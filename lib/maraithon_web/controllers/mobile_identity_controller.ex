defmodule MaraithonWeb.MobileIdentityController do
  @moduledoc """
  Identity confirmation for the mobile app: who the user is across
  channels, prefilled from connected accounts and their own messages.
  """

  use MaraithonWeb, :controller

  alias Maraithon.UserIdentity

  def show(conn, _params) do
    user_id = conn.assigns.current_user.id
    confirmed? = UserIdentity.confirmed?(user_id)

    prefill =
      if confirmed? do
        profile = UserIdentity.profile(user_id)

        %{
          display_name: profile.display_name,
          emails: profile.emails,
          phones: profile.phones
        }
      else
        UserIdentity.onboarding_prefill(user_id)
      end

    json(conn, %{
      identity: %{
        confirmed: confirmed?,
        display_name: prefill.display_name,
        emails: prefill.emails,
        phones: prefill.phones
      }
    })
  end

  def update(conn, params) do
    user_id = conn.assigns.current_user.id

    attrs = %{
      display_name: params["display_name"],
      emails: List.wrap(params["emails"]),
      phones: List.wrap(params["phones"])
    }

    case UserIdentity.confirm(user_id, attrs) do
      {:ok, profile} ->
        json(conn, %{
          identity: %{
            confirmed: true,
            display_name: profile.display_name,
            emails: profile.emails,
            phones: profile.phones
          }
        })

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{message: "Could not save identity details."}})
    end
  end
end
