defmodule Maraithon.Runtime.DatabaseClock do
  @moduledoc false

  alias Maraithon.Repo

  def now! do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  def window!(milliseconds) when is_integer(milliseconds) and milliseconds > 0 do
    %{rows: [[now, deadline]]} =
      Repo.query!(
        """
        WITH authority_time AS (SELECT clock_timestamp() AS now)
        SELECT now, now + ($1::bigint * interval '1 millisecond')
        FROM authority_time
        """,
        [milliseconds]
      )

    {now, deadline}
  end
end
