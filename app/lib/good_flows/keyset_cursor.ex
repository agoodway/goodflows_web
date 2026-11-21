defmodule GoodFlows.KeysetCursor do
  @moduledoc """
  Changeset step for keyset pagination.

  Replaces a string `cursor` change with the caller's decoded position.
  Spry run lists and workflow-run lists each keep their own cursor grammar.
  Lists keyed on one positive integer (review policy versions, change
  request numbers) share `encode_integer/1` and `decode_integer/1`.
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

  @doc """
  Casts `"limit"` (1 to `max`, default `default`) and an `encode_integer/1`
  `"cursor"` from list params, as `{:ok, %{limit: _, cursor: _}}` or a
  changeset error.
  """
  @spec integer_page_params(map(), pos_integer(), pos_integer()) ::
          {:ok, %{limit: pos_integer(), cursor: pos_integer() | nil}}
          | {:error, Ecto.Changeset.t()}
  def integer_page_params(params, default, max) do
    {%{limit: default, cursor: nil}, %{limit: :integer, cursor: :string}}
    |> Ecto.Changeset.cast(params, [:limit, :cursor], empty_values: [])
    |> Ecto.Changeset.validate_number(:limit,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: max
    )
    |> put_cursor(&decode_integer/1)
    |> Ecto.Changeset.apply_action(:list)
  end

  @doc "Encodes a positive integer keyset position as an opaque cursor."
  @spec encode_integer(pos_integer()) :: String.t()
  def encode_integer(position), do: Base.url_encode64("v1:#{position}", padding: false)

  @doc "Decodes a cursor from `encode_integer/1`."
  @spec decode_integer(String.t()) :: {:ok, pos_integer()} | :error
  def decode_integer(cursor) do
    with {:ok, "v1:" <> digits} <- Base.url_decode64(cursor, padding: false),
         true <- Regex.match?(~r/\A[1-9][0-9]{0,15}\z/, digits) do
      {:ok, String.to_integer(digits)}
    else
      _other -> :error
    end
  end
end
