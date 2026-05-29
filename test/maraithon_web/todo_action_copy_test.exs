defmodule MaraithonWeb.TodoActionCopyTest do
  use ExUnit.Case, async: true

  alias MaraithonWeb.TodoActionCopy

  test "not found copy gives recovery guidance" do
    assert TodoActionCopy.error(:complete, :not_found) ==
             "That work item is no longer available. Refresh the list to see current open work."
  end

  test "generic action copy hides internal reasons" do
    assert TodoActionCopy.error(:complete, {:db, :timeout}) ==
             "Could not mark that work item done. Refresh the list and use the latest row."

    assert TodoActionCopy.error(:dismiss, {:db, :timeout}) ==
             "Could not dismiss that work item. Refresh the list and use the latest row."

    assert TodoActionCopy.error(:see_less, {:db, :timeout}) ==
             "Could not save that feedback. Refresh the list and use the latest row."

    assert TodoActionCopy.error(:mark_important, {:db, :timeout}) ==
             "Could not mark that work item important. Refresh the list and use the latest row."
  end
end
