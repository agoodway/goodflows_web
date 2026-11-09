defmodule GoodFlows.ChangesetErrors do
  @moduledoc """
  Changeset helpers shared by request validation: bulk errors for
  `GoodFlows.Spry.Recipe`, and the keyset `cursor` step used by run lists.
  """

  @doc """
  Replaces a string `cursor` change with `decode.(cursor)`.

  A missing cursor is left alone. `:error` from `decode` is `is invalid`
  on `cursor`. Callers keep their own cursor grammar.
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

  @doc """
  Prepends `errors` (`{field, {message, opts}}`, in order) to the
  changeset's errors and marks it invalid; a no-op for `[]`.

  `Ecto.Changeset.add_error/4` is specced for atom keys, so errors are
  prepended directly: indexed keys such as `"setup[2]"` stay strings and
  never create atoms from request data. Atom and string keys are both
  supported downstream.
  """
  @spec prepend(Ecto.Changeset.t(), [{atom() | String.t(), {String.t(), keyword()}}]) ::
          Ecto.Changeset.t()
  def prepend(changeset, []), do: changeset

  def prepend(%Ecto.Changeset{errors: existing} = changeset, errors) do
    %{changeset | errors: Enum.reverse(errors) ++ existing, valid?: false}
  end

  @doc """
  One `{key, {message, validation: :unknown_key}}` error per key of `attrs`
  (string keys) not in `allowed`, sorted, for `prepend/2`. Keys are
  reported as given, so request data never creates atoms.
  """
  @spec unknown_keys(map(), [String.t()], String.t()) :: [{String.t(), {String.t(), keyword()}}]
  def unknown_keys(attrs, allowed, message) do
    attrs
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed))
    |> Enum.sort()
    |> Enum.map(&{&1, {message, validation: :unknown_key}})
  end
end
