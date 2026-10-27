defmodule Maraithon.Lineage.Transaction do
  @moduledoc false

  alias Maraithon.Repo

  def require do
    if Repo.in_transaction?(),
      do: :ok,
      else: {:error, :lineage_transaction_required}
  end
end
