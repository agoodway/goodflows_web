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
          send(self(), {:url, url})
        end)
      after
        Logger.configure(level: previous)
      end

    assert_received {:url, url}
    signature = query(url)["X-Amz-Signature"]
    refute log =~ signature
    refute log =~ "X-Amz-Signature"
    refute log =~ @secret
  end

  test "configured?/0 needs a bucket" do
    assert ObjectStore.configured?()
    config = Application.get_env(:good_flows, ObjectStore)
    Application.put_env(:good_flows, ObjectStore, Keyword.put(config, :bucket, nil))
    refute ObjectStore.configured?()
  end
end
