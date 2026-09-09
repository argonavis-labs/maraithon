defmodule Maraithon.PeopleNetwork.Compatibility do
  @moduledoc "Publishes existing CRM summary fields from the same projection, without rescanning sources."
  alias Maraithon.Repo

  def publish!(user_id, generation_id) do
    Repo.query!(
      """
      UPDATE crm_people AS person SET
        communication_score = (profile.profile->>'direct_score')::integer,
        network_rank = round((profile.profile->>'rank')::numeric)::integer,
        metadata = (COALESCE(person.metadata, '{}'::jsonb) - 'graph_signals') ||
          jsonb_build_object('communication_signals', profile.profile->'communication_signals',
                            'graph_signals', profile.profile->'graph_signals')
      FROM people_network_profiles AS profile
      WHERE profile.generation_id = $1 AND profile.user_id = $2 AND profile.window_days = 90
        AND person.user_id = $2 AND person.id::text = profile.node_id
      """,
      [Ecto.UUID.dump!(generation_id), user_id]
    )

    Repo.query!(
      """
      UPDATE crm_people SET communication_score = 0, network_rank = 0,
        metadata = COALESCE(metadata, '{}'::jsonb) - 'communication_signals' - 'graph_signals'
      WHERE user_id = $2 AND NOT EXISTS (
        SELECT 1 FROM people_network_profiles
        WHERE generation_id = $1 AND user_id = $2 AND node_id = crm_people.id::text AND window_days = 90
      ) AND (communication_score != 0 OR network_rank != 0 OR metadata ? 'communication_signals' OR metadata ? 'graph_signals')
      """,
      [Ecto.UUID.dump!(generation_id), user_id]
    )
  end
end
