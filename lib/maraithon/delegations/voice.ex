defmodule Maraithon.Delegations.Voice do
  @moduledoc "A bounded voice snapshot per turn. No provider reads, training, or model calls."
  alias Maraithon.Delegations.Scope
  alias Maraithon.Memory.UserVoice

  def freeze(snapshot, user_id, scope) do
    Map.put_new_lazy(snapshot, "voice", fn -> load(user_id, scope) end)
  end

  def context(snapshot, scope), do: snapshot["voice"] || default(scope)

  defp load(user_id, %{"actor" => "as_user", "identity" => %{"provider" => provider}} = scope)
       when is_binary(provider) do
    profile = UserVoice.prompt_context(user_id, scope["provider"], provider: provider)

    if profile["status"] == "available" and is_nil(profile["metadata"]["fallback_reason"]) do
      default(scope)
      |> Map.merge(%{
        "source" => "account_profile",
        "account_id" => profile["metadata"]["account_id"],
        "memory_id" => profile["memory_id"],
        "updated_at" => profile["updated_at"],
        "content" => String.slice(profile["content"] || "", 0, 800)
      })
      |> version()
    else
      default(scope)
    end
  end

  defp load(_, scope), do: default(scope)

  defp default(scope) do
    assistant? = scope["actor"] == "as_assistant"

    %{
      "schema_version" => 1,
      "actor" => if(assistant?, do: "as_assistant", else: "as_user"),
      "source" => if(assistant?, do: "house", else: "explicit_style"),
      "content" =>
        if(assistant?,
          do:
            "Be brief, warm, and plain. Use concrete requests and short paragraphs. Write in the assistant's first person; never claim to be human. No em dashes or filler.",
          else:
            "Write naturally in the user's first person. Be direct and concise. Use short paragraphs and concrete next steps. No em dashes, filler, or assistant introductions."
        )
    }
    |> version()
  end

  defp version(voice), do: Map.put(voice, "version", Scope.hash(Map.delete(voice, "version")))
end
