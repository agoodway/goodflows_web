defmodule GoodFlowsWeb.Plugs.TestReportBody do
  @moduledoc """
  Admits, reads and decodes a test report upload body. Runs in
  `GoodFlowsWeb.Api.V1.TestReportController`, after authentication,
  write access and `GoodFlowsWeb.Plugs.LoadProject`, so a rejected key or
  project never has its body read. The endpoint leaves this route unparsed
  (`GoodFlowsWeb.Plugs.BodyParsers`).

  In order, without reading the body unless noted:

    1. `415` unless `Content-Type` is `application/json` (optionally
       `charset=utf-8`) and `Content-Encoding` is absent or `identity`
    2. `413` when the declared `Content-Length` exceeds the limit
    3. `503` with `Retry-After` when no admission slot
       (`GoodFlowsWeb.TestReportAdmission`) is free on this node or for the
       authenticated account
    4. reads the body in chunks of at most 1 MiB against one overall
       deadline: `408` once the deadline passes, `413` as soon as more than
       the limit has arrived (whatever the adapter's return tag), `400` when
       it cannot be read
    5. `422` on `body` when objects/arrays nest deeper than
       `GoodFlows.TestReports.Document.max_depth/0`, found by a byte scan
       before decoding
    6. decodes with `GoodFlows.TestReports.Document.decode/1`: `400` for
       malformed JSON

  On success the decoded document is assigned as `:test_report_document`
  and the slot stays held: the controller calls `finish/1` once validation
  and persistence are done. On any rejection here the slot is released
  before responding. A slot is also released when the request process
  exits. While a slot is held the request process runs with a
  `max_heap_size` limit (restored by `finish/1`), a backstop that kills the
  process rather than let one upload exhaust node memory.

  Error bodies are fixed JSON whatever the `Accept` header (`{"errors":
  {"detail": ...}}`, or the validation shape for `422`) and never contain
  request data.

  Configuration, read on every request:

    * `:test_report_max_body_bytes` – body limit (default 33,554,432 bytes,
      32 MiB)
    * `:test_report_read_timeout_ms` – overall body read deadline (default
      60,000)
    * `:test_report_max_heap_bytes` – request process heap limit while a
      slot is held (default 2 GiB)
  """
  @behaviour Plug

  import Plug.Conn

  alias GoodFlows.TestReports.Document
  alias GoodFlowsWeb.{RawBody, RawBodyHeaders, TestReportAdmission}

  @default_max_body_bytes 33_554_432
  @default_read_timeout_ms 60_000
  @default_max_heap_bytes 2_147_483_648

  @doc "The configured body limit in bytes."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes,
    do: Application.get_env(:good_flows, :test_report_max_body_bytes, @default_max_body_bytes)

  @doc "The configured overall body read deadline in milliseconds."
  @spec read_timeout_ms() :: pos_integer()
  def read_timeout_ms,
    do: Application.get_env(:good_flows, :test_report_read_timeout_ms, @default_read_timeout_ms)

  @doc "The configured request process heap limit in bytes."
  @spec max_heap_bytes() :: pos_integer()
  def max_heap_bytes,
    do: Application.get_env(:good_flows, :test_report_max_heap_bytes, @default_max_heap_bytes)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    limit = max_body_bytes()

    with :ok <- RawBodyHeaders.check_json_content_type(conn),
         :ok <- RawBodyHeaders.check_content_encoding(conn),
         :ok <- RawBodyHeaders.check_declared_length(conn, limit),
         {:ok, conn} <- admit(conn) do
      conn
      |> read_and_decode(limit)
      |> respond()
    else
      {:error, reason} -> halt_with(conn, reason)
    end
  end

  @doc """
  Releases the admission slot taken by `call/2` and restores the request
  process heap limit. Safe to call more than once and on a conn that never
  held a slot.
  """
  @spec finish(Plug.Conn.t()) :: Plug.Conn.t()
  def finish(%Plug.Conn{private: %{test_report_admission: {slot, previous_heap}}} = conn) do
    TestReportAdmission.release(slot)
    Process.flag(:max_heap_size, previous_heap)
    %{conn | private: Map.delete(conn.private, :test_report_admission)}
  end

  def finish(%Plug.Conn{} = conn), do: conn

  defp respond({:ok, conn, document}), do: assign(conn, :test_report_document, document)
  defp respond({:error, conn, reason}), do: conn |> finish() |> halt_with(reason)

  defp admit(conn) do
    account_id = with %{id: id} <- conn.assigns[:current_account], do: id

    case TestReportAdmission.acquire(account_id) do
      {:ok, slot} ->
        words = div(max_heap_bytes(), :erlang.system_info(:wordsize))
        previous = Process.flag(:max_heap_size, %{size: words, kill: true, error_logger: true})
        {:ok, put_private(conn, :test_report_admission, {slot, previous})}

      :full ->
        {:error, :busy}
    end
  end

  # Any exception (such as an adapter raising on a socket timeout or a
  # client disconnect) releases the slot before propagating. The chunked
  # read itself lives in `RawBody` and does not know about the slot.
  defp read_and_decode(conn, limit) do
    deadline = System.monotonic_time(:millisecond) + read_timeout_ms()

    with {:ok, conn, body} <- RawBody.read(conn, limit, deadline),
         :ok <- check_depth(conn, body) do
      decode(conn, body)
    end
  catch
    kind, reason ->
      finish(conn)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp check_depth(conn, body) do
    case Document.check_depth(body) do
      :ok -> :ok
      {:error, :too_deep} -> {:error, conn, :too_deep}
    end
  end

  defp decode(conn, body) do
    case Document.decode(body) do
      {:ok, document} -> {:ok, conn, document}
      {:error, :malformed_json} -> {:error, conn, :malformed_json}
    end
  end

  defp halt_with(conn, :too_deep) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(422, Jason.encode!(%{errors: %{"body" => ["is nested too deeply"]}}))
    |> halt()
  end

  defp halt_with(conn, reason) do
    {status, detail} = error(reason)

    conn
    |> then(&if reason == :busy, do: put_resp_header(&1, "retry-after", "1"), else: &1)
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{errors: %{detail: detail}}))
    |> halt()
  end

  defp error(:unsupported_media_type),
    do: {415, "Content-Type must be application/json (charset utf-8)"}

  defp error(:unsupported_encoding), do: {415, "Content-Encoding must be absent or identity"}
  defp error(:too_large), do: {413, "Test report body exceeds the size limit"}
  defp error(:busy), do: {503, "Too many test report uploads in progress; retry later"}
  defp error(:timeout), do: {408, "Test report body was not received in time"}
  defp error(:unreadable), do: {400, "Test report body could not be read"}
  defp error(:malformed_json), do: {400, "Test report body is not valid JSON"}
end
