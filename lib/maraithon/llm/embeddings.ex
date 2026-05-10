defmodule Maraithon.LLM.Embeddings do
  @moduledoc """
  Provider-agnostic embedding generation for semantic CRM lookup and other
  retrieval-style features.

  Defaults to OpenAI's `text-embedding-3-small` (1536 dimensions). When no
  embedding provider is configured the runtime falls back to a deterministic
  mock embedder so tests and offline environments stay functional.
  """

  require Logger

  @default_model "text-embedding-3-small"
  @default_dim 1536
  @openai_url "https://api.openai.com/v1/embeddings"

  @type embedding :: [float()]

  @doc "Active embedding model id."
  def model, do: provider_config(:model, @default_model)

  @doc "Active embedding dimension count."
  def dimension, do: provider_config(:dimension, @default_dim)

  @doc """
  Compute an embedding for a string. Returns `{:ok, [float]}` or `{:error, reason}`.

  Options:
    * `:provider` - override the configured provider for this call
      (`:openai`, `:mock`, or a `{module, fun, extra_args}` tuple)
    * `:model` - override the model id
    * `:timeout_ms` - HTTP timeout, default 30_000
  """
  def embed(input, opts \\ [])

  def embed(input, opts) when is_binary(input) do
    text = String.trim(input)

    cond do
      text == "" ->
        {:error, :empty_input}

      true ->
        provider = Keyword.get(opts, :provider, configured_provider())

        case provider do
          :openai ->
            embed_via_openai(text, opts)

          :mock ->
            {:ok, deterministic_mock(text, dimension())}

          {module, fun, extra} when is_atom(module) and is_atom(fun) and is_list(extra) ->
            apply(module, fun, [text | extra])

          fun when is_function(fun, 1) ->
            fun.(text)

          other ->
            {:error, {:unknown_embedding_provider, other}}
        end
    end
  end

  def embed(_input, _opts), do: {:error, :invalid_input}

  defp embed_via_openai(text, opts) do
    case Maraithon.LLM.openai_api_key() do
      nil ->
        Logger.warning("OPENAI_API_KEY missing; falling back to mock embedding")
        {:ok, deterministic_mock(text, dimension())}

      "" ->
        Logger.warning("OPENAI_API_KEY empty; falling back to mock embedding")
        {:ok, deterministic_mock(text, dimension())}

      api_key ->
        do_openai_request(text, api_key, opts)
    end
  end

  defp do_openai_request(text, api_key, opts) do
    model = Keyword.get(opts, :model, model())
    timeout = Keyword.get(opts, :timeout_ms, 30_000)

    body = %{model: model, input: text}

    case Req.post(openai_url(),
           json: body,
           headers: [
             {"authorization", "Bearer #{api_key}"},
             {"content-type", "application/json"}
           ],
           receive_timeout: timeout
         ) do
      {:ok, %{status: 200, body: response}} ->
        case extract_embedding(response) do
          {:ok, vector} -> {:ok, vector}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{status: 429, body: body}} ->
        Logger.warning("Embedding rate limited", body: inspect(body))
        {:error, :rate_limited}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Embedding API error", status: status, body: inspect(body))
        {:error, {:api_error, status, body}}

      {:error, %{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, {:network_error, reason}}
    end
  end

  defp extract_embedding(%{"data" => [%{"embedding" => embedding} | _]})
       when is_list(embedding),
       do: {:ok, Enum.map(embedding, &normalize_float/1)}

  defp extract_embedding(_response), do: {:error, :missing_embedding}

  defp normalize_float(value) when is_float(value), do: value
  defp normalize_float(value) when is_integer(value), do: value * 1.0

  @doc """
  Deterministic pseudo-embedding for tests and offline use. Same input always
  produces the same vector, and similar inputs produce reasonably similar
  vectors (shared trigrams + length signal).
  """
  def deterministic_mock(text, dim) when is_binary(text) and is_integer(dim) and dim > 0 do
    seed = :erlang.phash2(text)

    text
    |> trigrams()
    |> Enum.reduce(zeros(dim), fn trigram, acc ->
      index = rem(:erlang.phash2(trigram), dim)
      List.update_at(acc, index, &(&1 + 1.0))
    end)
    |> add_length_signal(text, dim, seed)
    |> normalize_vector()
  end

  defp trigrams(text) do
    chars = text |> String.downcase() |> String.graphemes()

    case chars do
      [] -> []
      [_one] -> [Enum.join(chars)]
      [_a, _b] -> [Enum.join(chars)]
      _many -> for window <- Enum.chunk_every(chars, 3, 1, :discard), do: Enum.join(window)
    end
  end

  defp zeros(dim), do: List.duplicate(0.0, dim)

  defp add_length_signal(vector, text, dim, seed) do
    index = rem(seed, dim)
    boost = min(String.length(text) / 100.0, 1.0)
    List.update_at(vector, index, &(&1 + boost))
  end

  defp normalize_vector(vector) do
    norm =
      vector
      |> Enum.reduce(0.0, fn value, acc -> acc + value * value end)
      |> :math.sqrt()

    cond do
      norm == 0.0 -> vector
      true -> Enum.map(vector, &(&1 / norm))
    end
  end

  defp configured_provider do
    case Application.get_env(:maraithon, __MODULE__, [])
         |> Keyword.get(:provider, :auto) do
      :auto -> auto_provider()
      provider -> provider
    end
  end

  defp auto_provider do
    cond do
      Maraithon.LLM.openai_api_key() not in [nil, ""] -> :openai
      true -> :mock
    end
  end

  defp provider_config(key, default) do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp openai_url do
    provider_config(:openai_url, @openai_url)
  end
end
