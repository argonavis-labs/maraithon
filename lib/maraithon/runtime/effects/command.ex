defmodule Maraithon.Runtime.Effects.Command do
  @moduledoc """
  Command behavior for effect execution.

  This is the GoF Command pattern boundary: each effect type is encapsulated
  in its own executable command module.
  """

  alias Maraithon.Effects.Effect

  @callback prepare(effect :: Effect.t()) :: {:ok, term()} | {:error, term()}
  @callback execute_prepared(effect :: Effect.t(), prepared :: term()) ::
              {:ok, map()} | {:error, term()}
  @callback execute(effect :: Effect.t()) :: {:ok, map()} | {:error, term()}

  @callback revalidate_prepared_authority(
              effect :: Effect.t(),
              prepared :: term(),
              locked_authority :: map()
            ) :: :ok | {:error, term()}

  @optional_callbacks revalidate_prepared_authority: 3
end
