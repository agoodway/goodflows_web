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

  Multipart uploads: part URLs sign `content-length` and `content-md5`
  with the `partNumber` and `uploadId` query, so the store enforces each
  part's length and MD5. CreateMultipartUpload, ListParts (paged),
  CompleteMultipartUpload and AbortMultipartUpload are SigV4-signed `Req`
  requests whose query is built already encoded (the signer does not
  re-encode it; upload ids may contain `+`, `/` or `=`). Their XML is read
  by `GoodFlows.Caches.ObjectStore.S3XML`. Complete gets a 120-second
  receive timeout.

  Nothing here logs: URLs and signatures are credentials. Requests do not
  retry; a failed delete stays queued for the next sweep.
  """
  @behaviour GoodFlows.Caches.ObjectStore

  alias GoodFlows.Caches.ObjectStore
  alias GoodFlows.Caches.ObjectStore.S3XML

  @timeout_ms 15_000
  @complete_timeout_ms 120_000
  @max_part_number 10_000

  @impl ObjectStore
  def presign_put(object_key, %{size: size, sha256: sha256, expires_in: expires_in} = opts) do
    headers =
      ObjectStore.upload_headers(size, sha256, Map.get(opts, :content_type, "application/gzip"))

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
           checksum_sha256: header(response, "x-amz-checksum-sha256"),
           etag: response |> header("etag") |> strip_etag()
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

  @impl ObjectStore
  def create_multipart(object_key) do
    case request(:post, object_key,
           query: "uploads",
           headers: [{"content-type", "application/gzip"}]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case S3XML.upload_id(body) do
          {:ok, upload_id} -> {:ok, upload_id}
          :error -> {:error, :malformed_response}
        end

      other ->
        failure(other)
    end
  end

  @impl ObjectStore
  def presign_part(object_key, upload_id, number, %{size: size, md5: md5, expires_in: expires_in}) do
    headers = ObjectStore.part_headers(size, md5)

    url =
      presign(object_key,
        method: :put,
        expires: expires_in,
        headers: Enum.sort(headers),
        query: [{"partNumber", Integer.to_string(number)}, {"uploadId", upload_id}]
      )

    {url, headers}
  end

  @impl ObjectStore
  def list_parts(object_key, upload_id), do: list_parts(object_key, upload_id, 0, [])

  defp list_parts(object_key, upload_id, marker, acc) do
    query = "part-number-marker=#{marker}&uploadId=#{encode(upload_id)}"

    case request(:get, object_key, query: query) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case S3XML.list_parts(body) do
          {:ok, parts, nil} ->
            {:ok, Enum.reverse(acc, parts)}

          # A part number is at most 10,000, so a marker at or past it can
          # only come from a broken or hostile store; stop paging.
          {:ok, parts, next} when next > marker and next < @max_part_number ->
            list_parts(object_key, upload_id, next, Enum.reverse(parts, acc))

          _malformed ->
            {:error, :malformed_response}
        end

      other ->
        failure(other)
    end
  end

  @impl ObjectStore
  def complete_multipart(object_key, upload_id, parts) do
    body =
      [
        ~s(<CompleteMultipartUpload xmlns="http://s3.amazonaws.com/doc/2006-03-01/">),
        Enum.map(parts, fn {number, etag} ->
          [
            "<Part><PartNumber>",
            Integer.to_string(number),
            "</PartNumber><ETag>&quot;",
            xml_escape(etag),
            "&quot;</ETag></Part>"
          ]
        end),
        "</CompleteMultipartUpload>"
      ]
      |> IO.iodata_to_binary()

    case request(:post, object_key,
           query: "uploadId=" <> encode(upload_id),
           body: body,
           headers: [{"content-type", "application/xml"}],
           receive_timeout: @complete_timeout_ms
         ) do
      # S3 can report an error in a 200 body, after the response started.
      {:ok, %Req.Response{status: 200, body: body}} ->
        case S3XML.complete_result(body) do
          :error -> {:error, :malformed_response}
          result -> result
        end

      {:ok, %Req.Response{status: 400, body: body}} = response ->
        case S3XML.error_code(body) do
          code when code in [nil, ""] -> failure(response)
          code -> {:error, S3XML.classify(code)}
        end

      other ->
        failure(other)
    end
  end

  @impl ObjectStore
  def abort_multipart(object_key, upload_id) do
    case request(:delete, object_key, query: "uploadId=" <> encode(upload_id)) do
      {:ok, %Req.Response{status: status}} when status in [200, 204] -> :ok
      other -> failure(other)
    end
  end

  # `NoSuchUpload` is `{:error, :not_found}`; any other answer is a store
  # error (a missing bucket must not look like a finished upload).
  defp failure({:ok, %Req.Response{status: 404, body: body}}) do
    if S3XML.error_code(body) == "NoSuchUpload",
      do: {:error, :not_found},
      else: {:error, {:status, 404}}
  end

  defp failure({:ok, %Req.Response{status: status}}), do: {:error, {:status, status}}

  defp failure({:error, exception}), do: {:error, {:transport, Exception.message(exception)}}

  defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp xml_escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp strip_etag(nil), do: nil
  defp strip_etag(etag), do: etag |> String.trim() |> String.trim("\"") |> String.downcase()

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

  # `:query` is an already encoded query string.
  defp request(method, object_key, opts) do
    config = ObjectStore.config()
    {query, opts} = Keyword.pop(opts, :query)
    url = object_url(config, object_key)

    [
      method: method,
      url: if(query, do: url <> "?" <> query, else: url),
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
