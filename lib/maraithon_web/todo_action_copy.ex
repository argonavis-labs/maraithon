defmodule MaraithonWeb.TodoActionCopy do
  @moduledoc false

  def error(_action, :not_found) do
    "That work item is no longer available. Refresh the list to see current open work."
  end

  def error(:complete, _reason) do
    "Could not mark that work item done. Refresh the list and use the latest row."
  end

  def error(:dismiss, _reason) do
    "Could not dismiss that work item. Refresh the list and use the latest row."
  end

  def error(:see_less, _reason) do
    "Could not save that feedback. Refresh the list and use the latest row."
  end

  def error(:mark_important, _reason) do
    "Could not mark that work item important. Refresh the list and use the latest row."
  end

  def error(_action, _reason) do
    "Could not update that work item. Refresh the list and use the latest row."
  end
end
