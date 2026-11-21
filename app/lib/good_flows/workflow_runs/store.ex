defmodule GoodFlows.WorkflowRuns.Store do
  @moduledoc """
  The `GoodFlows.Repo` calls made by `GoodFlows.WorkflowRuns.ingest/4`,
  behind one thin module so tests can stub storage failures (with Mimic)
  without copying `GoodFlows.Repo` for the whole suite.
  """

  alias GoodFlows.Repo

  @doc "`Repo.insert_all/3`."
  @spec insert_all(module(), [map()], keyword()) :: {non_neg_integer(), nil | [term()]}
  def insert_all(schema, rows, opts), do: Repo.insert_all(schema, rows, opts)

  @doc "`Repo.transaction/2`; the commit point of an upload."
  @spec transaction((-> term()), keyword()) :: {:ok, term()} | {:error, term()}
  def transaction(fun, opts), do: Repo.transaction(fun, opts)

  @doc "`Repo.one/2`."
  @spec one(Ecto.Queryable.t(), keyword()) :: term()
  def one(query, opts), do: Repo.one(query, opts)
end
