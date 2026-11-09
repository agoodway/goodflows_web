defmodule GoodFlows.KeysetCursor do
  @moduledoc """
  Changeset step for keyset pagination.

  Replaces a string `cursor` change with the caller's decoded position.
  Spry run lists and workflow-run lists each keep their own cursor grammar.
  """

  @doc """
  Replaces a string `cursor` change with `decode.(cursor)`.

  A missing cursor is left alone. `:error` from `decode` is `is invalid`
  on `cursor`.
  """
  @spec put_cursor(Ecto.Changeset.t(), (String.t() -> {:ok, term()} | :error)) ::
          Ecto.Changeset.t()
  def put_cursor(changeset, decode) when is_function(decode, 1) do
    case Ecto.Changeset.get_change(changeset, :cursor) do
      nil -> changeset
      cursor -> store_cursor(changeset, decode.(cursor))
    end
  end

  defp store_cursor(changeset, {:ok, decoded}),
    do: Ecto.Changeset.put_change(changeset, :cursor, decoded)

  defp store_cursor(changeset, :error),
    do: Ecto.Changeset.add_error(changeset, :cursor, "is invalid")
end
