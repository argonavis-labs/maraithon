defmodule Maraithon.Lineage.ChangesetValidators do
  @moduledoc false

  import Ecto.Changeset

  def validate_digest(changeset, field) do
    validate_length(changeset, field, is: 32, count: :bytes)
  end

  def validate_object(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value) and not is_struct(value), do: [], else: [{field, "must be an object"}]
    end)
  end

  def validate_bytes(changeset, field, opts) do
    changeset
    |> validate_length(
      field,
      opts |> Keyword.take([:min, :max, :is]) |> Keyword.put(:count, :bytes)
    )
    |> validate_change(field, fn ^field, value ->
      if is_binary(value) and String.valid?(value) and
           not Regex.match?(~r/[\x00-\x1F\x7F]/u, value) do
        []
      else
        [{field, "contains invalid characters"}]
      end
    end)
  end
end
