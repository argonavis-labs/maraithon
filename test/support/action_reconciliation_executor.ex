defmodule Maraithon.TestSupport.ActionReconciliationExecutor do
  @moduledoc false
  def execute_prepared_action(action) do
    Application.fetch_env!(:maraithon, :action_reconciliation_executor).(action)
  end
end
