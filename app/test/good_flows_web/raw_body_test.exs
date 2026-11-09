defmodule GoodFlowsWeb.RawBodyTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias GoodFlowsWeb.GreedyBodyAdapter
  alias GoodFlowsWeb.RawBody

  defp far_deadline, do: System.monotonic_time(:millisecond) + 60_000

  defp read(body, limit, opts \\ []) do
    conn = :post |> conn("/", body) |> GreedyBodyAdapter.wrap(opts)
    RawBody.read(conn, limit, far_deadline())
  end

  test "a body exactly at the limit is returned whole" do
    body = String.duplicate("a", 8)

    assert {:ok, _conn, ^body} = read(body, 8)
  end

  test "an adapter returning {:ok, body, conn} one byte over the limit is too large" do
    assert {:error, _conn, :too_large} = read(String.duplicate("a", 9), 8)
  end

  test "a later {:more, ...} chunk that crosses the limit is too large" do
    # 6-byte reads: the first stays under the limit, the second is still
    # {:more, ...} (bytes remain) and pushes the total over.
    body = String.duplicate("a", 14)

    assert {:error, _conn, :too_large} = read(body, 8, trickle: {6, 0})
  end

  test "chunks that sum exactly to the limit are accepted" do
    body = String.duplicate("a", 8)

    assert {:ok, _conn, ^body} = read(body, 8, trickle: {3, 0})
  end

  test "a deadline that has already passed does not read the body" do
    conn = conn(:post, "/", "hello")
    deadline = System.monotonic_time(:millisecond) - 1

    assert {:error, returned, :timeout} = RawBody.read(conn, 100, deadline)
    assert {:ok, "hello", _} = Plug.Conn.read_body(returned)
  end

  test "an adapter error is unreadable" do
    assert {:error, _conn, :unreadable} = read("hello", 100, error: :closed)
  end

  test "an adapter timeout is a timeout" do
    assert {:error, _conn, :timeout} = read("hello", 100, error: :timeout)
  end
end
