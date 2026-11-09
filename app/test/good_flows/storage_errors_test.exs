defmodule GoodFlows.StorageErrorsTest.ExampleError do
  @moduledoc false
  defexception [:sqlstate, :constraint]

  @impl Exception
  def message(%{sqlstate: sqlstate}),
    do: "example storage failed (SQLSTATE #{sqlstate || "unknown"})"
end

defmodule GoodFlows.StorageErrorsTest do
  use ExUnit.Case, async: true

  alias GoodFlows.StorageErrors
  alias GoodFlows.StorageErrorsTest.ExampleError

  @opts [
    unavailable: :example_unavailable,
    project_fkey: "example_project_id_fkey",
    storage_error: ExampleError,
    label: "Example storage failed"
  ]

  defp postgres_error(pg_code, extra \\ %{}) do
    %Postgrex.Error{
      postgres:
        Map.merge(%{code: nil, pg_code: pg_code, severity: "ERROR", message: "boom"}, extra)
    }
  end

  test "a successful call returns the function result" do
    assert StorageErrors.persist(fn -> {:ok, 1} end, @opts) == {:ok, 1}
  end

  test "a dropped connection has no SQLSTATE and is unavailable, not the storage error" do
    result =
      StorageErrors.persist(
        fn -> raise DBConnection.ConnectionError, "tcp recv: closed" end,
        @opts
      )

    assert result == {:error, :example_unavailable}
    refute StorageErrors.transient?(nil)
  end

  test "the project foreign key is not_found and any other foreign key is unavailable" do
    project_gone = fn ->
      raise postgres_error("23503", %{constraint: "example_project_id_fkey"})
    end

    assert StorageErrors.persist(project_gone, @opts) == {:error, :not_found}

    other_fk = fn -> raise postgres_error("23503", %{constraint: "example_api_key_id_fkey"}) end
    assert StorageErrors.persist(other_fk, @opts) == {:error, :example_unavailable}

    missing_name = fn -> raise postgres_error("23503", %{constraint: nil}) end
    assert StorageErrors.persist(missing_name, @opts) == {:error, :example_unavailable}
  end

  test "transient SQLSTATE classes and the two extra codes are unavailable" do
    for pg_code <- ~w(08006 40001 40P01 53100 57014 57P03 55P03 25006) do
      assert StorageErrors.transient?(pg_code), pg_code

      assert StorageErrors.persist(fn -> raise postgres_error(pg_code) end, @opts) ==
               {:error, :example_unavailable},
             pg_code
    end

    refute StorageErrors.transient?("22P05")
    refute StorageErrors.transient?("23505")
  end

  test "any other database error re-raises the given module and logs only the SQLSTATE" do
    sentinel = "SENTINEL-postgres-detail-91c2"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        error =
          assert_raise ExampleError, fn ->
            StorageErrors.persist(
              fn ->
                raise postgres_error("22P05", %{
                        message: "unsupported Unicode escape #{sentinel}",
                        detail: sentinel,
                        constraint: nil
                      })
              end,
              @opts
            )
          end

        assert Exception.message(error) == "example storage failed (SQLSTATE 22P05)"
        assert error.sqlstate == "22P05"
        assert error.constraint == nil
        refute inspect(error) =~ sentinel
      end)

    assert log =~ "Example storage failed: SQLSTATE 22P05, constraint none"
    refute log =~ sentinel
  end

  test "a Postgrex error with no SQLSTATE is still the storage error, not a dropped connection" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        error =
          assert_raise ExampleError, fn ->
            StorageErrors.persist(fn -> raise %Postgrex.Error{postgres: %{}} end, @opts)
          end

        assert error.sqlstate == nil
        assert Exception.message(error) == "example storage failed (SQLSTATE unknown)"
      end)

    assert log =~ "SQLSTATE unknown"
  end
end
