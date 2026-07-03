defmodule Maraithon.LLM.EmbeddingsTest do
  use ExUnit.Case, async: false

  alias Maraithon.LLM.Embeddings

  setup do
    original = Application.get_env(:maraithon, Embeddings)
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime)

    on_exit(fn ->
      if original do
        Application.put_env(:maraithon, Embeddings, original)
      else
        Application.delete_env(:maraithon, Embeddings)
      end

      if original_runtime do
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)
      else
        Application.delete_env(:maraithon, Maraithon.Runtime)
      end
    end)

    :ok
  end

  describe "embed/2 with explicit mock provider" do
    test "returns a deterministic vector for the same input" do
      {:ok, a} = Embeddings.embed("Charlie Smith", provider: :mock)
      {:ok, b} = Embeddings.embed("Charlie Smith", provider: :mock)

      assert a == b
      assert length(a) == Embeddings.dimension()
    end

    test "different inputs produce different vectors" do
      {:ok, a} = Embeddings.embed("Charlie Smith", provider: :mock)
      {:ok, b} = Embeddings.embed("Justin Wright", provider: :mock)

      refute a == b
    end

    test "rejects empty input" do
      assert {:error, :empty_input} = Embeddings.embed("", provider: :mock)
      assert {:error, :empty_input} = Embeddings.embed("   ", provider: :mock)
    end

    test "rejects non-string input" do
      assert {:error, :invalid_input} = Embeddings.embed(nil, provider: :mock)
      assert {:error, :invalid_input} = Embeddings.embed(123, provider: :mock)
    end

    test "vectors are length-1 (cosine ready)" do
      {:ok, vec} = Embeddings.embed("Charlie Smith", provider: :mock)
      norm = vec |> Enum.reduce(0.0, fn v, acc -> acc + v * v end) |> :math.sqrt()
      assert_in_delta norm, 1.0, 1.0e-6
    end
  end

  describe "embed/2 with custom function provider" do
    test "delegates to the provided function" do
      assert {:ok, [0.5, 0.5]} =
               Embeddings.embed("hello", provider: fn _text -> {:ok, [0.5, 0.5]} end)
    end

    test "propagates errors from the provider" do
      assert {:error, :unavailable} =
               Embeddings.embed("hello", provider: fn _text -> {:error, :unavailable} end)
    end
  end

  describe "embed_many/2 with explicit mock provider" do
    test "returns one vector per input, in order" do
      {:ok, [a, b]} =
        Embeddings.embed_many(["Charlie Smith", "Justin Wright"], provider: :mock)

      {:ok, single_a} = Embeddings.embed("Charlie Smith", provider: :mock)
      {:ok, single_b} = Embeddings.embed("Justin Wright", provider: :mock)

      assert a == single_a
      assert b == single_b
    end

    test "returns {:ok, []} for an empty list" do
      assert {:ok, []} = Embeddings.embed_many([], provider: :mock)
    end

    test "rejects a blank entry" do
      assert {:error, :empty_input} = Embeddings.embed_many(["ok", ""], provider: :mock)
    end
  end

  describe "embed_many/2 with custom function provider" do
    test "calls the provider once per input and preserves order" do
      assert {:ok, [[0.1], [0.2]]} =
               Embeddings.embed_many(["a", "b"],
                 provider: fn
                   "a" -> {:ok, [0.1]}
                   "b" -> {:ok, [0.2]}
                 end
               )
    end

    test "propagates a provider error" do
      assert {:error, :unavailable} =
               Embeddings.embed_many(["a", "b"], provider: fn _text -> {:error, :unavailable} end)
    end
  end

  describe "auto-selection" do
    test "falls back to mock when no OpenAI key configured" do
      runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

      Application.put_env(
        :maraithon,
        Maraithon.Runtime,
        Keyword.put(runtime, :openai_api_key, nil)
      )

      assert {:ok, vec} = Embeddings.embed("hello world")
      assert is_list(vec)
    end
  end
end
