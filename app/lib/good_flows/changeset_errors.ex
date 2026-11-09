defmodule GoodFlows.ChangesetErrors do
  @moduledoc """
  Bulk error helpers for schemas that validate request-shaped bodies
  (`GoodFlows.Spry.Recipe`).
  """

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
