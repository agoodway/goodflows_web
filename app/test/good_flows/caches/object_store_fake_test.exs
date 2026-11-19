defmodule GoodFlows.Caches.ObjectStoreFakeTest do
  use ExUnit.Case, async: true

  alias GoodFlows.Caches.ObjectStore
  alias GoodFlows.Caches.ObjectStore.Fake

  setup do
    prefix = "caches/fake-test-#{System.unique_integer([:positive])}/"
    object_key = prefix <> "object"
    {:ok, upload_id} = ObjectStore.create_multipart(object_key)
    %{prefix: prefix, object_key: object_key, upload_id: upload_id}
  end

  defp md5(body), do: Base.encode64(:crypto.hash(:md5, body))

  defp presign(ctx, number, body, md5 \\ nil) do
    ObjectStore.presign_part(ctx.object_key, ctx.upload_id, number, %{
      size: byte_size(body),
      md5: md5 || md5(body),
      expires_in: 7_200
    })
  end

  test "a part with its signed headers and body is accepted and listed", ctx do
    {url, headers} = presign(ctx, 1, "part one")
    assert headers == ObjectStore.part_headers(8, md5("part one"))
    assert url =~ "partNumber=1"
    assert url =~ Fake.signature()
    assert :ok = Fake.put_part(url, headers, "part one")

    hex = Base.encode16(:crypto.hash(:md5, "part one"), case: :lower)

    assert {:ok, [%{number: 1, etag: ^hex, size: 8}]} =
             ObjectStore.list_parts(ctx.object_key, ctx.upload_id)
  end

  test "a wrong body is :bad_digest, a wrong length :length_mismatch", ctx do
    {url, headers} = presign(ctx, 1, "part one")
    assert {:error, :bad_digest} = Fake.put_part(url, headers, "part two")
    assert {:error, :length_mismatch} = Fake.put_part(url, headers, "part one!")
    assert {:ok, []} = ObjectStore.list_parts(ctx.object_key, ctx.upload_id)
  end

  test "a missing or changed header is :signature_mismatch", ctx do
    {url, headers} = presign(ctx, 1, "part one")

    assert {:error, :signature_mismatch} =
             Fake.put_part(url, Map.delete(headers, "content-md5"), "part one")

    assert {:error, :signature_mismatch} =
             Fake.put_part(url, Map.put(headers, "content-md5", md5("x")), "x")
  end

  test "a part after abort is :no_such_upload", ctx do
    {url, headers} = presign(ctx, 1, "part one")
    assert :ok = ObjectStore.abort_multipart(ctx.object_key, ctx.upload_id)
    assert {:error, :no_such_upload} = Fake.put_part(url, headers, "part one")
    assert {:error, :not_found} = ObjectStore.abort_multipart(ctx.object_key, ctx.upload_id)
    assert {:error, :not_found} = ObjectStore.list_parts(ctx.object_key, ctx.upload_id)
    refute Fake.exists?(ctx.object_key)
  end

  test "a re-uploaded part replaces the earlier one", ctx do
    {url, headers} = presign(ctx, 1, "first")
    assert :ok = Fake.put_part(url, headers, "first")
    {url, headers} = presign(ctx, 1, "again")
    assert :ok = Fake.put_part(url, headers, "again")

    hex = Base.encode16(:crypto.hash(:md5, "again"), case: :lower)

    assert {:ok, [%{number: 1, etag: ^hex}]} =
             ObjectStore.list_parts(ctx.object_key, ctx.upload_id)
  end

  test "complete creates the multipart ETag, the summed size and no SHA-256", ctx do
    bodies = ["first part", "second", "third!"]

    for {body, number} <- Enum.with_index(bodies, 1) do
      {url, headers} = presign(ctx, number, body)
      assert :ok = Fake.put_part(url, headers, body)
    end

    {:ok, parts} = ObjectStore.list_parts(ctx.object_key, ctx.upload_id)
    refute Fake.exists?(ctx.object_key)

    assert :ok =
             ObjectStore.complete_multipart(
               ctx.object_key,
               ctx.upload_id,
               Enum.map(parts, &{&1.number, &1.etag})
             )

    concatenated = bodies |> Enum.map(&:crypto.hash(:md5, &1)) |> IO.iodata_to_binary()
    etag = Base.encode16(:crypto.hash(:md5, concatenated), case: :lower) <> "-3"
    assert ObjectStore.multipart_etag(Enum.map(bodies, &md5/1)) == etag

    assert {:ok, %{size: 22, checksum_sha256: nil, etag: ^etag}} =
             ObjectStore.head(ctx.object_key)

    assert Fake.body(ctx.object_key) == Enum.join(bodies)
    assert Fake.upload_state(ctx.upload_id) == :completed
    assert {:error, :not_found} = ObjectStore.list_parts(ctx.object_key, ctx.upload_id)

    assert {:error, :not_found} =
             ObjectStore.complete_multipart(ctx.object_key, ctx.upload_id, [{1, "x"}])
  end

  test "complete with a wrong ETag is rejected as InvalidPart", ctx do
    {url, headers} = presign(ctx, 1, "part")
    assert :ok = Fake.put_part(url, headers, "part")

    assert {:error, {:rejected, "InvalidPart"}} =
             ObjectStore.complete_multipart(ctx.object_key, ctx.upload_id, [{1, "00"}])

    assert Fake.upload_state(ctx.upload_id) == :open
  end

  test "failures are injected per call and prefix and healed", ctx do
    Fake.fail(:list_parts, ctx.prefix)
    assert {:error, :unavailable} = ObjectStore.list_parts(ctx.object_key, ctx.upload_id)
    assert {:ok, []} = ObjectStore.list_parts("caches/other/object", ctx.upload_id)
    Fake.heal(:list_parts, ctx.prefix)
    assert {:ok, []} = ObjectStore.list_parts(ctx.object_key, ctx.upload_id)

    Fake.fail(:complete_multipart, ctx.prefix, {:error, {:rejected, "EntityTooSmall"}})

    assert {:error, {:rejected, "EntityTooSmall"}} =
             ObjectStore.complete_multipart(ctx.object_key, ctx.upload_id, [{1, "x"}])

    Fake.fail(:create_multipart, ctx.prefix)
    assert {:error, :unavailable} = ObjectStore.create_multipart(ctx.prefix <> "new")
  end

  test "complete_upload/1 completes behind the server's back", ctx do
    {url, headers} = presign(ctx, 1, "part")
    assert :ok = Fake.put_part(url, headers, "part")
    assert :ok = Fake.complete_upload(ctx.upload_id)
    assert {:ok, %{size: 4, etag: etag}} = ObjectStore.head(ctx.object_key)
    assert etag == ObjectStore.multipart_etag([md5("part")])
  end
end
