defmodule GoodFlows.JsonValue do
  @moduledoc """
  Ecto type for a `jsonb` column that holds any JSON value, such as an
  array of verdict reasons. Ecto's `:map` type accepts only objects.
  Values are stored and loaded as given; nothing is rewritten.
  """
  use Ecto.Type

  @impl Ecto.Type
  def type, do: :map

  @impl Ecto.Type
  def cast(value), do: {:ok, value}

  @impl Ecto.Type
  def load(value), do: {:ok, value}

  @impl Ecto.Type
  def dump(value), do: {:ok, value}
end
