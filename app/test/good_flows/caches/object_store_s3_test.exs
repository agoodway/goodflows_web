defmodule GoodFlows.Caches.ObjectStoreS3Test do
  # Swaps the global object store config, so it runs after the async tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias GoodFlows.Caches.ObjectStore
  alias GoodFlows.Caches.ObjectStore.S3

  @secret "s3-secret-access-key-sentinel"
  @sha256 :sha256 |> :crypto.hash("archive") |> Base.encode16(case: :lower)

  setup do
    original = Application.get_env(:good_flows, ObjectStore)

    Application.put_env(:good_flows, ObjectStore,
      adapter: S3,
      bucket: "caches",
      # Unroutable: requests fail fast and never reach a real store.
      endpoint: "http://127.0.0.1:9",
      region: "auto",
      access_key_id: "AKIDEXAMPLE",
      secret_access_key: @secret
    )

    on_exit(fn -> Application.put_env(:good_flows, ObjectStore, original) end)
  end

  defp query(url), do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  test "the presigned PUT signs content-length, content-type and the SHA-256 checksum" do
    {url, headers} =
      S3.presign_put("caches/p/u", %{size: 52_428_800, sha256: @sha256, expires_in: 900})

    assert headers == %{
             "content-length" => "52428800",
             "content-type" => "application/gzip",
             "x-amz-checksum-sha256" => @sha256 |> Base.decode16!(case: :lower) |> Base.encode64()
           }

    assert url =~ ~r{\Ahttp://127\.0\.0\.1:9/caches/caches/p/u\?}
    params = query(url)

    assert params["X-Amz-SignedHeaders"] ==
             "content-length;content-type;host;x-amz-checksum-sha256"

    assert params["X-Amz-Expires"] == "900"
    assert params["X-Amz-Credential"] =~ ~r"\AAKIDEXAMPLE/\d{8}/auto/s3/aws4_request\z"
    assert params["X-Amz-Signature"] =~ ~r/\A[0-9a-f]{64}\z/
    refute url =~ @secret
  end

  test "both URLs carry the configured TTLs" do
    {put_url, _headers} =
      S3.presign_put("caches/p/u", %{size: 1, sha256: @sha256, expires_in: 123})

    assert query(put_url)["X-Amz-Expires"] == "123"

    get_url = S3.presign_get("caches/p/u", %{expires_in: 456})
    assert query(get_url)["X-Amz-Expires"] == "456"
    assert query(get_url)["X-Amz-SignedHeaders"] == "host"
  end

  test "a different checksum or size changes the signature" do
    {a, _} = S3.presign_put("k", %{size: 10, sha256: @sha256, expires_in: 900})
    {b, _} = S3.presign_put("k", %{size: 11, sha256: @sha256, expires_in: 900})

    {c, _} =
      S3.presign_put("k", %{size: 10, sha256: String.duplicate("0", 64), expires_in: 900})

    signatures = Enum.map([a, b, c], &query(&1)["X-Amz-Signature"])
    assert Enum.uniq(signatures) == signatures
  end

  test "without an endpoint the URL is AWS S3 virtual-hosted" do
    config = Application.get_env(:good_flows, ObjectStore)

    Application.put_env(
      :good_flows,
      ObjectStore,
      Keyword.merge(config, endpoint: nil, region: "eu-west-1")
    )

    assert S3.presign_get("caches/p/u", %{expires_in: 60}) =~
             ~r{\Ahttps://caches\.s3\.eu-west-1\.amazonaws\.com/caches/p/u\?}
  end

  test "nothing is logged at :debug, even when the store is unreachable" do
    previous = Logger.level()
    Logger.configure(level: :debug)

    log =
      try do
        capture_log([level: :debug], fn ->
          {url, _} = S3.presign_put("caches/p/u", %{size: 1, sha256: @sha256, expires_in: 900})
          _ = S3.presign_get("caches/p/u", %{expires_in: 900})
          assert {:error, {:transport, _}} = S3.head("caches/p/u")
          assert {:error, {:transport, _}} = S3.delete("caches/p/u")
          assert {:error, {:transport, _}} = S3.create_multipart("caches/p/u")
          assert {:error, {:transport, _}} = S3.list_parts("caches/p/u", "id")
          assert {:error, {:transport, _}} = S3.complete_multipart("caches/p/u", "id", [{1, "e"}])
          assert {:error, {:transport, _}} = S3.abort_multipart("caches/p/u", "id")

          {part_url, _} =
            S3.presign_part("caches/p/u", "id", 1, %{size: 5, md5: "md5", expires_in: 60})

          send(self(), {:part_url, part_url})
          send(self(), {:url, url})
        end)
      after
        Logger.configure(level: previous)
      end

    assert_received {:url, url}
    assert_received {:part_url, part_url}
    signature = query(url)["X-Amz-Signature"]
    refute log =~ signature
    refute log =~ query(part_url)["X-Amz-Signature"]
    refute log =~ "X-Amz-Signature"
    refute log =~ @secret
  end

  describe "multipart" do
    @upload_id "abc+def/ghi=="

    test "a part URL signs content-length, content-md5 and host, with its query and TTL" do
      md5 = Base.encode64(:crypto.hash(:md5, "part"))

      {url, headers} =
        S3.presign_part("caches/p/u", @upload_id, 7, %{
          size: 16_777_216,
          md5: md5,
          expires_in: 7_200
        })

      assert headers == %{"content-length" => "16777216", "content-md5" => md5}
      params = query(url)
      assert params["X-Amz-SignedHeaders"] == "content-length;content-md5;host"
      assert params["X-Amz-Expires"] == "7200"
      assert params["partNumber"] == "7"
      assert params["uploadId"] == @upload_id
      raw = URI.parse(url).query
      assert raw =~ "uploadId=abc%2Bdef%2Fghi%3D%3D"
      refute raw =~ @upload_id

      {other, _headers} =
        S3.presign_part("caches/p/u", @upload_id, 8, %{
          size: 16_777_216,
          md5: md5,
          expires_in: 7_200
        })

      refute query(other)["X-Amz-Signature"] == params["X-Amz-Signature"]
    end

    test "store requests send the encoded upload id and map the responses" do
      test_pid = self()

      plug = fn conn, _opts ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, conn.method, conn.request_path, conn.query_string, body})
        auth = Plug.Conn.get_req_header(conn, "authorization")
        true = match?(["AWS4-HMAC-SHA256 " <> _], auth)
        {status, response} = respond(conn.method, conn.query_string)
        Plug.Conn.send_resp(conn, status, response)
      end

      pid = start_supervised!({Bandit, plug: plug, ip: :loopback, port: 0, startup_log: false})
      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      config = Application.get_env(:good_flows, ObjectStore)

      Application.put_env(
        :good_flows,
        ObjectStore,
        Keyword.put(config, :endpoint, "http://127.0.0.1:#{port}")
      )

      encoded = "abc%2Bdef%2Fghi%3D%3D"

      assert {:ok, @upload_id} = S3.create_multipart("caches/p/u")
      assert_received {:request, "POST", "/caches/caches/p/u", "uploads", ""}

      assert {:ok, [%{number: 1, etag: "aa", size: 5}, %{number: 2, etag: "bb", size: 3}]} =
               S3.list_parts("caches/p/u", @upload_id)

      assert_received {:request, "GET", _, "part-number-marker=0&uploadId=" <> ^encoded, _}
      assert_received {:request, "GET", _, "part-number-marker=1&uploadId=" <> ^encoded, _}

      assert :ok = S3.complete_multipart("caches/p/u", @upload_id, [{1, "aa"}, {2, "bb"}])
      assert_received {:request, "POST", _, "uploadId=" <> ^encoded, xml}
      assert xml =~ "<Part><PartNumber>2</PartNumber><ETag>&quot;bb&quot;</ETag></Part>"

      assert {:error, {:rejected, "InvalidPart"}} =
               S3.complete_multipart("caches/p/u", "rejected-in-200", [{1, "aa"}])

      assert {:error, {:store_error, "InternalError"}} =
               S3.complete_multipart("caches/p/u", "internal-in-200", [{1, "aa"}])

      assert {:error, {:rejected, "EntityTooSmall"}} =
               S3.complete_multipart("caches/p/u", "too-small", [{1, "aa"}])

      assert {:error, {:store_error, "RequestTimeout"}} =
               S3.complete_multipart("caches/p/u", "timeout-400", [{1, "aa"}])

      assert {:error, :malformed_response} = S3.list_parts("caches/p/u", "runaway")

      assert {:error, :not_found} = S3.complete_multipart("caches/p/u", "gone", [{1, "aa"}])
      assert {:error, :not_found} = S3.list_parts("caches/p/u", "gone")
      assert {:error, :not_found} = S3.abort_multipart("caches/p/u", "gone")
      assert {:error, {:status, 404}} = S3.abort_multipart("caches/p/u", "no-bucket")
      assert {:error, {:status, 503}} = S3.abort_multipart("caches/p/u", "busy")
      assert :ok = S3.abort_multipart("caches/p/u", @upload_id)
      assert_received {:request, "DELETE", _, "uploadId=" <> ^encoded, _}
    end
  end

  defp respond("POST", "uploads"),
    do:
      {200,
       "<InitiateMultipartUploadResult><Bucket>caches</Bucket><Key>caches/p/u</Key>" <>
         "<UploadId>abc+def/ghi==</UploadId></InitiateMultipartUploadResult>"}

  defp respond("GET", "part-number-marker=0&uploadId=runaway"),
    do:
      {200,
       "<ListPartsResult><IsTruncated>true</IsTruncated><NextPartNumberMarker>10000</NextPartNumberMarker>" <>
         "<Part><PartNumber>1</PartNumber><ETag>&quot;aa&quot;</ETag><Size>5</Size></Part></ListPartsResult>"}

  defp respond("GET", "part-number-marker=0&" <> _),
    do:
      {200,
       "<ListPartsResult><IsTruncated>true</IsTruncated><NextPartNumberMarker>1</NextPartNumberMarker>" <>
         "<Part><PartNumber>1</PartNumber><ETag>&quot;AA&quot;</ETag><Size>5</Size></Part></ListPartsResult>"}

  defp respond("GET", "part-number-marker=1&uploadId=" <> id) when id != "gone",
    do:
      {200,
       "<ListPartsResult><IsTruncated>false</IsTruncated>" <>
         "<Part><PartNumber>2</PartNumber><ETag>\"bb\"</ETag><Size>3</Size></Part></ListPartsResult>"}

  defp respond("POST", "uploadId=rejected-in-200"),
    do: {200, "<Error><Code>InvalidPart</Code><Message>m</Message></Error>"}

  defp respond("POST", "uploadId=internal-in-200"),
    do: {200, "<Error><Code>InternalError</Code></Error>"}

  defp respond("POST", "uploadId=timeout-400"),
    do: {400, "<Error><Code>RequestTimeout</Code></Error>"}

  defp respond("POST", "uploadId=too-small"),
    do: {400, "<Error><Code>EntityTooSmall</Code></Error>"}

  defp respond("POST", "uploadId=gone"), do: {404, "<Error><Code>NoSuchUpload</Code></Error>"}

  defp respond("POST", "uploadId=" <> _),
    do:
      {200,
       "<CompleteMultipartUploadResult><ETag>&quot;x-2&quot;</ETag></CompleteMultipartUploadResult>"}

  defp respond("DELETE", "uploadId=no-bucket"),
    do: {404, "<Error><Code>NoSuchBucket</Code></Error>"}

  defp respond("DELETE", "uploadId=busy"), do: {503, "<Error><Code>SlowDown</Code></Error>"}
  defp respond("DELETE", "uploadId=gone"), do: {404, "<Error><Code>NoSuchUpload</Code></Error>"}
  defp respond("DELETE", _query), do: {204, ""}
  defp respond(_method, _query), do: {404, "<Error><Code>NoSuchUpload</Code></Error>"}

  test "configured?/0 needs a bucket" do
    assert ObjectStore.configured?()
    config = Application.get_env(:good_flows, ObjectStore)
    Application.put_env(:good_flows, ObjectStore, Keyword.put(config, :bucket, nil))
    refute ObjectStore.configured?()
  end
end
