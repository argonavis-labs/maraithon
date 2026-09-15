defmodule MaraithonWeb.DelegationCopy do
  @moduledoc false
  def error(:delegations_disabled), do: "Delegation isn't available for this account yet."

  def error(reason) when reason in [:scope_changed, :todo_changed],
    do: "The task or sending identity changed. Review it again."

  def error({:conflict, _}), do: "This conversation changed. Its latest status is shown."
  def error(:already_delegated), do: "Maraithon is already following up on this task."

  def error(reason)
      when reason in [
             :sending_identity_unavailable,
             :google_account_not_connected,
             :no_token,
             :reauth_required
           ],
      do: "Connect the sending account in Settings, then try again."

  def error(:assistant_identity_required), do: "Set up your assistant in Settings first."

  def error(:gmail_sending_permission_required),
    do:
      "This account cannot send Gmail yet. Connect it with Gmail sending permission to continue."

  def error(:source_is_not_sent_mail), do: "A draft cannot be the evidence for a delegation."
  def error(:invalid_answer), do: "Enter an answer of up to 2,000 characters."

  def error(reason)
      when reason in [:invalid_work_days, :invalid_work_hours, :invalid_timezone, :invalid_limits],
      do: "Check your working days, hours, timezone, and limits, then save again."

  def error(:invalid_calendar_accounts),
    do: "Choose a connected calendar or scheduling link that belongs to you."

  def error(_),
    do: "Could not verify this delegation. Refresh the task and check its source account."

  def control("take_over"), do: "Take over"
  def control(value) when value in ~w(pause resume stop answer), do: String.capitalize(value)
end
