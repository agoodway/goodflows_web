defmodule GoodFlows.StorageErrors do
  @moduledoc """
  Classifies Postgres failures from an insert-or-compare storage call.

  A dropped connection (`DBConnection.ConnectionError`) has no SQLSTATE and
  is the caller's unavailable result, never a storage-error exception. A
  violation of the caller's project foreign key is `:not_found`. Any other
  foreign key, or a transient SQLSTATE (classes 08, 40, 53 and 57, plus
  `55P03` and `25006`), is the same unavailable result. Any other
  `Postgrex.Error` is logged with only its SQLSTATE and constraint name
  and re-raised as the caller's storage-error module.

  `TestReports` and later workflow-run storage each pass their own
  unavailable atom, project foreign-key name, exception module and log
  label. The Postgres message and detail are never logged or stored on
  the exception: they can quote the submitted document.
  """

  require Logger

  # SQLSTATE classes meaning the server could not finish the statement now,
  # rather than that the request was wrong: 08 connection exception,
  # 40 transaction rollback (serialization failure, deadlock), 53
  # insufficient resources, 57 operator intervention (query canceled,
  # shutdown, cannot connect now).
  @transient_classes ["08", "40", "53", "57"]
  # 55P03 lock_not_available; 25006 read_only_sql_transaction (a failover
  # left the connection on a standby).
  @transient_codes ["55P03", "25006"]

  @typedoc """
  Options for `persist/2`:

    * `:unavailable` – error atom for a dropped connection, a transient
      SQLSTATE, or a foreign key other than `:project_fkey`
    * `:project_fkey` – constraint name that means the path's project is gone
    * `:storage_error` – exception module re-raised for any other
      `Postgrex.Error`; it must accept `:sqlstate` and `:constraint`
    * `:label` – fixed prefix of the error log, before the SQLSTATE
  """
  @type opts :: [
          unavailable: atom(),
          project_fkey: String.t(),
          storage_error: module(),
          label: String.t()
        ]

  @doc """
  Runs `fun` and classifies database failures as described in the module
  documentation. A successful call returns `fun`'s result unchanged.
  """
  @spec persist((-> result), opts()) :: result | {:error, :not_found | atom()}
        when result: term()
  def persist(fun, opts) when is_function(fun, 0) do
    fun.()
  rescue
    DBConnection.ConnectionError ->
      {:error, Keyword.fetch!(opts, :unavailable)}

    error in Postgrex.Error ->
      classify(error, opts, __STACKTRACE__)
  end

  @doc """
  Whether `sqlstate` is a transient failure. `nil` is not: a dropped
  connection has no SQLSTATE and is classified by `persist/2` before this
  check.
  """
  @spec transient?(String.t() | nil) :: boolean()
  def transient?(sqlstate) when is_binary(sqlstate),
    do: String.starts_with?(sqlstate, @transient_classes) or sqlstate in @transient_codes

  def transient?(nil), do: false

  defp classify(error, opts, stacktrace) do
    sqlstate = sqlstate(error)
    unavailable = Keyword.fetch!(opts, :unavailable)

    cond do
      sqlstate == "23503" -> foreign_key_error(error, opts, unavailable)
      transient?(sqlstate) -> {:error, unavailable}
      true -> reraise_fixed(error, sqlstate, opts, stacktrace)
    end
  end

  # Only the project foreign key means the path's project is gone. Any
  # other reference vanishing between authentication and insert is
  # unavailable for this request: a retry re-runs authentication.
  defp foreign_key_error(error, opts, unavailable) do
    if constraint(error) == Keyword.fetch!(opts, :project_fkey),
      do: {:error, :not_found},
      else: {:error, unavailable}
  end

  defp reraise_fixed(error, sqlstate, opts, stacktrace) do
    name = constraint(error)
    label = Keyword.fetch!(opts, :label)

    Logger.error("#{label}: SQLSTATE #{sqlstate || "unknown"}, constraint #{name || "none"}")

    reraise Keyword.fetch!(opts, :storage_error),
            [sqlstate: sqlstate, constraint: name],
            stacktrace
  end

  defp sqlstate(%Postgrex.Error{postgres: %{pg_code: code}}) when is_binary(code), do: code
  defp sqlstate(%Postgrex.Error{}), do: nil

  defp constraint(%Postgrex.Error{postgres: %{constraint: name}}) when is_binary(name), do: name
  defp constraint(%Postgrex.Error{}), do: nil
end
