defmodule GoodFlowsWeb.Plugs.WorkflowRunBody do
  @moduledoc """
  Reads and decodes a workflow-run upload body. Runs in
  `GoodFlowsWeb.Api.V1.WorkflowRunController` for `:create`, after
  authentication, write access and `GoodFlowsWeb.Plugs.LoadProject`, so a
  rejected key or project never has its body read. The endpoint leaves
  `POST` on this path unparsed (`GoodFlowsWeb.Plugs.BodyParsers`).

  In order, without reading the body unless noted:

    1. `415` unless `Content-Type` is `application/json` (optionally
       `charset=utf-8`) and `Content-Encoding` is absent or `identity`
    2. `413` when the declared `Content-Length` exceeds the limit
    3. reads the body in chunks of at most 1 MiB against one overall
       deadline (`GoodFlowsWeb.RawBody`): `408` once the deadline passes,
       `413` as soon as more than the limit has arrived, `400` when it
       cannot be read
    4. `422` on `body` when objects or arrays nest deeper than
       `GoodFlows.WorkflowRuns.Validator.max_depth/0` (8)
    5. decodes with `GoodFlows.JsonDocument.decode/1`: `400` for malformed
       JSON
    6. `GoodFlows.JsonDocument.normalize/1`: duplicate keys, U+0000 and
       integers outside ±(2^53 − 1) are `422`, with paths cut back to
       contract keys

  On success the normalized term is stored at
  `:workflow_run_document` in `conn.private`. The controller never reads
  `conn.params` for the body. Non-integer numbers pass `normalize/1`; the
  validator rejects them.

  Error bodies are fixed JSON whatever the `Accept` header and never
  contain request data.

  Configuration, read on every request:

    * `:workflow_run_max_body_bytes` – body limit (default 4,194,304 bytes,
      4 MiB)
    * `:workflow_run_read_timeout_ms` – overall body read deadline (default
      30,000)
  """
  @behaviour Plug

  import Plug.Conn

  alias GoodFlows.JsonDocument
  alias GoodFlows.WorkflowRuns.Validator
  alias GoodFlowsWeb.{RawBody, RawBodyHeaders}

  @default_max_body_bytes 4_194_304
  @default_read_timeout_ms 30_000

  @doc "The configured body limit in bytes."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes do
    Application.get_env(:good_flows, :workflow_run_max_body_bytes, @default_max_body_bytes)
  end

  @doc "The configured overall body read deadline in milliseconds."
  @spec read_timeout_ms() :: pos_integer()
  def read_timeout_ms do
    Application.get_env(:good_flows, :workflow_run_read_timeout_ms, @default_read_timeout_ms)
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    limit = max_body_bytes()

    with :ok <- RawBodyHeaders.check_json_content_type(conn),
         :ok <- RawBodyHeaders.check_content_encoding(conn),
         :ok <- RawBodyHeaders.check_declared_length(conn, limit),
         {:ok, conn, document} <- read_and_decode(conn, limit) do
      put_private(conn, :workflow_run_document, document)
    else
      {:error, reason} -> halt_with(conn, reason)
      {:error, returned, reason} -> halt_with(returned, reason)
    end
  end

  # Depth, decode and normalize errors carry the post-read conn. `with`
  # does not rebind names into `else`, so each step returns the conn itself.
  defp read_and_decode(conn, limit) do
    deadline = System.monotonic_time(:millisecond) + read_timeout_ms()

    with {:ok, conn, body} <- RawBody.read(conn, limit, deadline),
         :ok <- check_depth(conn, body),
         {:ok, decoded} <- decode(conn, body) do
      normalize(conn, decoded)
    end
  end

  defp check_depth(conn, body) do
    case JsonDocument.check_depth(body, Validator.max_depth()) do
      :ok -> :ok
      {:error, :too_deep} -> {:error, conn, :too_deep}
    end
  end

  defp decode(conn, body) do
    case JsonDocument.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, :malformed_json} -> {:error, conn, :malformed_json}
    end
  end

  defp normalize(conn, decoded) do
    case JsonDocument.normalize(decoded) do
      {:ok, document} -> {:ok, conn, document}
      {:error, errors} -> {:error, conn, {:invalid, Validator.render_errors(errors)}}
    end
  end

  defp halt_with(conn, :too_deep) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(422, Jason.encode!(%{errors: %{"body" => ["is nested too deeply"]}}))
    |> halt()
  end

  defp halt_with(conn, {:invalid, errors}) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(422, Jason.encode!(%{errors: errors}))
    |> halt()
  end

  defp halt_with(conn, reason) do
    {status, detail} = error(reason)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{errors: %{detail: detail}}))
    |> halt()
  end

  defp error(:unsupported_media_type),
    do: {415, "Content-Type must be application/json (charset utf-8)"}

  defp error(:unsupported_encoding), do: {415, "Content-Encoding must be absent or identity"}
  defp error(:too_large), do: {413, "Workflow run body exceeds the size limit"}
  defp error(:timeout), do: {408, "Workflow run body was not received in time"}
  defp error(:unreadable), do: {400, "Workflow run body could not be read"}
  defp error(:malformed_json), do: {400, "Workflow run body is not valid JSON"}
end
