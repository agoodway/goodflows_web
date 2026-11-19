defmodule GoodFlows.Caches.ObjectStore.S3 do
  @moduledoc """
  `GoodFlows.Caches.ObjectStore` on an S3-compatible bucket through
  `req_s3`: `ReqS3.presign_url/1` for both presigned URLs, and SigV4-signed
  `Req` `HEAD` and `DELETE` requests.

  Settings (`config :good_flows, GoodFlows.Caches.ObjectStore`): `:bucket`,
  `:endpoint` (path-style `<endpoint>/<bucket>/<key>`; without it, AWS S3
  virtual-hosted URLs), `:region`, `:access_key_id` and
  `:secret_access_key`.

  The PUT URL signs `content-length`, `content-type` and
  `x-amz-checksum-sha256`, so the store rejects a body whose length or
  SHA-256 differs from the reservation, and a PUT without those headers
  fails signature verification. `HEAD` asks for checksum mode so the
  response carries `x-amz-checksum-sha256`.

  Nothing here logs: URLs and signatures are credentials. Requests do not
  retry; a failed delete stays queued for the next sweep.
  """
  @behaviour GoodFlows.Caches.ObjectStore

  alias GoodFlows.Caches.ObjectStore

  @timeout_ms 15_000

  @impl ObjectStore
  def presign_put(object_key, %{size: size, sha256: sha256, expires_in: expires_in}) do
    headers = ObjectStore.upload_headers(size, sha256)

    url =
      presign(object_key,
        method: :put,
        expires: expires_in,
        headers: Enum.sort(headers)
      )

    {url, headers}
  end

  @impl ObjectStore
  def presign_get(object_key, %{expires_in: expires_in}) do
    presign(object_key, method: :get, expires: expires_in)
  end

  @impl ObjectStore
  def head(object_key) do
    case request(:head, object_key, headers: [{"x-amz-checksum-mode", "ENABLED"}]) do
      {:ok, %Req.Response{status: 200} = response} ->
        {:ok,
         %{
           size: response |> header("content-length") |> parse_size(),
           checksum_sha256: header(response, "x-amz-checksum-sha256")
         }}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:status, status}}

      {:error, exception} ->
        {:error, {:transport, Exception.message(exception)}}
    end
  end

  @impl ObjectStore
  def delete(object_key) do
    case request(:delete, object_key, []) do
      {:ok, %Req.Response{status: status}} when status in [200, 204] -> :ok
      {:ok, %Req.Response{status: 404}} -> {:error, :not_found}
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, exception} -> {:error, {:transport, Exception.message(exception)}}
    end
  end

  defp presign(object_key, opts) do
    config = ObjectStore.config()

    ReqS3.presign_url(
      [
        url: object_url(config, object_key),
        access_key_id: Keyword.fetch!(config, :access_key_id),
        secret_access_key: Keyword.fetch!(config, :secret_access_key),
        region: region(config)
      ] ++ opts
    )
  end

  defp request(method, object_key, opts) do
    config = ObjectStore.config()

    [
      method: method,
      url: object_url(config, object_key),
      aws_sigv4: [
        access_key_id: Keyword.fetch!(config, :access_key_id),
        secret_access_key: Keyword.fetch!(config, :secret_access_key),
        region: region(config),
        service: :s3
      ],
      retry: false,
      receive_timeout: @timeout_ms,
      decode_body: false
    ]
    |> Keyword.merge(opts)
    |> Req.request()
  end

  defp object_url(config, object_key) do
    bucket = Keyword.fetch!(config, :bucket)

    case config[:endpoint] do
      endpoint when endpoint in [nil, ""] ->
        "https://#{bucket}.s3.#{region(config)}.amazonaws.com/#{object_key}"

      endpoint ->
        "#{String.trim_trailing(endpoint, "/")}/#{bucket}/#{object_key}"
    end
  end

  defp region(config) do
    case config[:region] do
      region when region in [nil, ""] -> "us-east-1"
      region -> region
    end
  end

  defp header(response, name) do
    case Req.Response.get_header(response, name) do
      [value | _rest] -> value
      [] -> nil
    end
  end

  defp parse_size(nil), do: nil

  defp parse_size(value) do
    case Integer.parse(value) do
      {size, ""} -> size
      _other -> nil
    end
  end
end
