defmodule GoodFlows.Caches.ObjectStore.Fake do
  @moduledoc """
  In-memory `GoodFlows.Caches.ObjectStore` for tests (selected in
  `config/test.exs`, started by `test/test_helper.exs`).

  Presigned URLs point at `https://fake-object-store.invalid/<key>` and end
  with `X-Amz-Signature=` `signature/0`, a sentinel tests search logs for.
  `put/3` simulates a client PUT to a presigned URL: it is rejected unless
  the request sends exactly the headers signed into the URL, its body length
  equals `content-length`, and its SHA-256 equals `x-amz-checksum-sha256`.

  Multipart uploads are `:open`, `:completed` or `:aborted`. `put_part/3`
  simulates a part PUT to a URL from `presign_part/4`, enforcing the signed
  headers, the length and `content-md5` as R2 does, and replacing an earlier
  upload of the same part number. Completing an upload creates the object
  with the summed size, the multipart ETag and no SHA-256; its body (the
  concatenated parts) is readable with `body/1`.

  `fail/3` makes one call fail for object keys under a prefix (tests use
  `"caches/<project_id>/"`, so async tests do not interfere).
  """
  @behaviour GoodFlows.Caches.ObjectStore

  use Agent

  alias GoodFlows.Caches.ObjectStore

  @host "https://fake-object-store.invalid/"
  @signature "FAKESIGNATURESENTINEL0123456789abcdef"

  @typedoc "A call `fail/3` can make fail."
  @type call ::
          :head
          | :delete
          | :create_multipart
          | :list_parts
          | :complete_multipart
          | :abort_multipart

  @doc "Starts the store under its module name."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(
      fn ->
        %{
          objects: %{},
          signed: %{},
          failing: MapSet.new(),
          failing_calls: %{},
          uploads: %{},
          part_signed: %{}
        }
      end,
      name: __MODULE__
    )
  end

  @doc "The signature every presigned URL carries."
  @spec signature() :: String.t()
  def signature, do: @signature

  @impl ObjectStore
  def presign_put(object_key, %{size: size, sha256: sha256, expires_in: expires_in} = opts) do
    headers =
      ObjectStore.upload_headers(size, sha256, Map.get(opts, :content_type, "application/gzip"))

    Agent.update(__MODULE__, &put_in(&1, [:signed, object_key], headers))
    {url(object_key, expires_in, signed_list(headers), []), headers}
  end

  @impl ObjectStore
  def presign_get(object_key, %{expires_in: expires_in}),
    do: url(object_key, expires_in, "host", [])

  @impl ObjectStore
  def head(object_key) do
    state = Agent.get(__MODULE__, & &1)

    cond do
      MapSet.member?(state.failing, object_key) ->
        {:error, :unavailable}

      error = injected(state, :head, object_key) ->
        error

      object = state.objects[object_key] ->
        {:ok, Map.take(object, [:size, :checksum_sha256, :etag])}

      true ->
        {:error, :not_found}
    end
  end

  @impl ObjectStore
  def delete(object_key) do
    Agent.get_and_update(__MODULE__, fn state ->
      cond do
        MapSet.member?(state.failing, object_key) -> {{:error, :unavailable}, state}
        error = injected(state, :delete, object_key) -> {error, state}
        Map.has_key?(state.objects, object_key) -> {:ok, delete_object(state, object_key)}
        true -> {{:error, :not_found}, state}
      end
    end)
  end

  @impl ObjectStore
  def create_multipart(object_key) do
    Agent.get_and_update(__MODULE__, fn state ->
      if error = injected(state, :create_multipart, object_key) do
        {error, state}
      else
        upload_id = "fake+upload/" <> Base.encode64(:crypto.strong_rand_bytes(12))
        upload = %{object_key: object_key, state: :open, parts: %{}}
        {{:ok, upload_id}, put_in(state, [:uploads, upload_id], upload)}
      end
    end)
  end

  @impl ObjectStore
  def presign_part(object_key, upload_id, number, %{size: size, md5: md5, expires_in: expires_in}) do
    headers = ObjectStore.part_headers(size, md5)
    Agent.update(__MODULE__, &put_in(&1, [:part_signed, {upload_id, number}], headers))

    query = [{"partNumber", Integer.to_string(number)}, {"uploadId", upload_id}]
    {url(object_key, expires_in, signed_list(headers), query), headers}
  end

  @impl ObjectStore
  def list_parts(object_key, upload_id) do
    state = Agent.get(__MODULE__, & &1)

    cond do
      error = injected(state, :list_parts, object_key) ->
        error

      match?(%{state: :open}, state.uploads[upload_id]) ->
        parts =
          state.uploads[upload_id].parts
          |> Enum.sort_by(fn {number, _part} -> number end)
          |> Enum.map(fn {number, part} ->
            %{number: number, etag: part.etag, size: part.size}
          end)

        {:ok, parts}

      true ->
        {:error, :not_found}
    end
  end

  @impl ObjectStore
  def complete_multipart(object_key, upload_id, parts) do
    Agent.get_and_update(__MODULE__, fn state ->
      upload = state.uploads[upload_id]

      cond do
        error = injected(state, :complete_multipart, object_key) ->
          {error, state}

        not match?(%{state: :open}, upload) ->
          {{:error, :not_found}, state}

        parts == [] ->
          {{:error, {:rejected, "MalformedXML"}}, state}

        Enum.any?(parts, fn {number, etag} ->
          String.trim(etag, "\"") != get_in(upload, [:parts, number, :etag])
        end) ->
          {{:error, {:rejected, "InvalidPart"}}, state}

        true ->
          {:ok, complete(state, upload_id, Enum.map(parts, &elem(&1, 0)))}
      end
    end)
  end

  @impl ObjectStore
  def abort_multipart(object_key, upload_id) do
    Agent.get_and_update(__MODULE__, fn state ->
      cond do
        error = injected(state, :abort_multipart, object_key) ->
          {error, state}

        match?(%{state: :open}, state.uploads[upload_id]) ->
          {:ok, put_in(state, [:uploads, upload_id, :state], :aborted)}

        true ->
          {{:error, :not_found}, state}
      end
    end)
  end

  @doc """
  Simulates a PUT of `body` with `headers` to a presigned upload `url`.
  Returns `:ok` or `{:error, :signature_mismatch | :length_mismatch | :bad_digest}`.
  """
  @spec put(String.t(), map(), binary()) :: :ok | {:error, atom()}
  def put(url, headers, body) do
    object_key = url |> URI.parse() |> Map.fetch!(:path) |> String.trim_leading("/")
    signed = Agent.get(__MODULE__, &get_in(&1, [:signed, object_key]))
    checksum = :sha256 |> :crypto.hash(body) |> Base.encode64()

    cond do
      signed == nil or signed != headers ->
        {:error, :signature_mismatch}

      headers["content-length"] != Integer.to_string(byte_size(body)) ->
        {:error, :length_mismatch}

      headers["x-amz-checksum-sha256"] != checksum ->
        {:error, :bad_digest}

      true ->
        put_object(object_key, byte_size(body), checksum, hex_md5(body))
    end
  end

  @doc """
  Simulates a PUT of `body` with `headers` to a presigned part `url`.
  Returns `:ok` or `{:error, :signature_mismatch | :no_such_upload |
  :length_mismatch | :bad_digest}`.
  """
  @spec put_part(String.t(), map(), binary()) :: :ok | {:error, atom()}
  def put_part(url, headers, body) do
    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    upload_id = query["uploadId"]
    number = String.to_integer(query["partNumber"])

    Agent.get_and_update(__MODULE__, fn state ->
      signed = state.part_signed[{upload_id, number}]

      cond do
        signed == nil or signed != headers ->
          {{:error, :signature_mismatch}, state}

        not match?(%{state: :open}, state.uploads[upload_id]) ->
          {{:error, :no_such_upload}, state}

        headers["content-length"] != Integer.to_string(byte_size(body)) ->
          {{:error, :length_mismatch}, state}

        headers["content-md5"] != Base.encode64(:crypto.hash(:md5, body)) ->
          {{:error, :bad_digest}, state}

        true ->
          part = %{etag: hex_md5(body), size: byte_size(body), body: body}
          {:ok, put_in(state, [:uploads, upload_id, :parts, number], part)}
      end
    end)
  end

  @doc """
  Completes open upload `upload_id` from all its uploaded parts directly,
  as if a commit had completed it before failing.
  """
  @spec complete_upload(String.t()) :: :ok
  def complete_upload(upload_id) do
    Agent.update(__MODULE__, fn state ->
      numbers = state.uploads[upload_id].parts |> Map.keys() |> Enum.sort()
      complete(state, upload_id, numbers)
    end)
  end

  @doc "The state of `upload_id`: `:open`, `:completed`, `:aborted`, or `nil`."
  @spec upload_state(String.t()) :: :open | :completed | :aborted | nil
  def upload_state(upload_id),
    do: Agent.get(__MODULE__, &get_in(&1, [:uploads, upload_id, :state]))

  @doc "The `{upload_id, object_key, state}` of every upload under `prefix`."
  @spec uploads(String.t()) :: [{String.t(), String.t(), atom()}]
  def uploads(prefix) do
    Agent.get(__MODULE__, fn state ->
      for {id, upload} <- state.uploads,
          String.starts_with?(upload.object_key, prefix),
          do: {id, upload.object_key, upload.state}
    end)
  end

  @doc "The body of a completed multipart object, or `nil`."
  @spec body(String.t()) :: binary() | nil
  def body(object_key), do: Agent.get(__MODULE__, &get_in(&1, [:objects, object_key, :body]))

  @doc "Stores object metadata directly, as if the store had recorded it."
  @spec put_object(String.t(), non_neg_integer(), String.t() | nil, String.t() | nil) :: :ok
  def put_object(object_key, size, checksum_sha256, etag \\ nil) do
    object = %{size: size, checksum_sha256: checksum_sha256, etag: etag, body: nil}
    Agent.update(__MODULE__, &put_in(&1, [:objects, object_key], object))
  end

  @doc "Whether the store holds `object_key`."
  @spec exists?(String.t()) :: boolean()
  def exists?(object_key), do: Agent.get(__MODULE__, &Map.has_key?(&1.objects, object_key))

  @doc "Makes `head/1` and `delete/1` of `object_key` fail until `heal/1`."
  @spec fail_deletes(String.t()) :: :ok
  def fail_deletes(object_key),
    do:
      Agent.update(__MODULE__, &update_in(&1.failing, fn set -> MapSet.put(set, object_key) end))

  @doc "Lets `head/1` and `delete/1` of `object_key` succeed again."
  @spec heal(String.t()) :: :ok
  def heal(object_key),
    do:
      Agent.update(
        __MODULE__,
        &update_in(&1.failing, fn set -> MapSet.delete(set, object_key) end)
      )

  @doc """
  Makes `call` return `error` (default `{:error, :unavailable}`) for every
  object key starting with `prefix`, until `heal/2`.
  """
  @spec fail(call(), String.t(), term()) :: :ok
  def fail(call, prefix, error \\ {:error, :unavailable}),
    do: Agent.update(__MODULE__, &put_in(&1, [:failing_calls, {call, prefix}], error))

  @doc "Undoes `fail/3`."
  @spec heal(call(), String.t()) :: :ok
  def heal(call, prefix),
    do:
      Agent.update(
        __MODULE__,
        &update_in(&1.failing_calls, fn m -> Map.delete(m, {call, prefix}) end)
      )

  defp injected(state, call, object_key) do
    Enum.find_value(state.failing_calls, fn {{failing_call, prefix}, error} ->
      if failing_call == call and String.starts_with?(object_key, prefix), do: error
    end)
  end

  defp complete(state, upload_id, numbers) do
    upload = state.uploads[upload_id]
    parts = Enum.map(numbers, &upload.parts[&1])
    md5s = Enum.map(parts, &Base.encode64(:crypto.hash(:md5, &1.body)))

    object = %{
      size: parts |> Enum.map(& &1.size) |> Enum.sum(),
      checksum_sha256: nil,
      etag: ObjectStore.multipart_etag(md5s),
      body: parts |> Enum.map(& &1.body) |> IO.iodata_to_binary()
    }

    state
    |> put_in([:objects, upload.object_key], object)
    |> put_in([:uploads, upload_id, :state], :completed)
    |> put_in([:uploads, upload_id, :parts], %{})
  end

  defp delete_object(state, object_key) do
    %{state | objects: Map.delete(state.objects, object_key)}
  end

  defp hex_md5(body), do: :md5 |> :crypto.hash(body) |> Base.encode16(case: :lower)

  defp signed_list(headers),
    do: headers |> Map.keys() |> Kernel.++(["host"]) |> Enum.sort() |> Enum.join(";")

  defp url(object_key, expires_in, signed_headers, extra_query) do
    query =
      URI.encode_query(
        extra_query ++
          [
            {"X-Amz-Algorithm", "AWS4-HMAC-SHA256"},
            {"X-Amz-Expires", Integer.to_string(expires_in)},
            {"X-Amz-SignedHeaders", signed_headers},
            {"X-Amz-Signature", @signature}
          ]
      )

    @host <> object_key <> "?" <> query
  end
end
