defmodule GoodFlows.Caches.ObjectStore.Fake do
  @moduledoc """
  In-memory `GoodFlows.Caches.ObjectStore` for tests (selected in
  `config/test.exs`, started by `test/test_helper.exs`).

  Presigned URLs point at `https://fake-object-store.invalid/<key>` and end
  with `X-Amz-Signature=` `signature/0`, a sentinel tests search logs for.
  `put/3` simulates a client PUT to a presigned URL: it is rejected unless
  the request sends exactly the headers signed into the URL, its body length
  equals `content-length`, and its SHA-256 equals `x-amz-checksum-sha256`.
  """
  @behaviour GoodFlows.Caches.ObjectStore

  use Agent

  alias GoodFlows.Caches.ObjectStore

  @host "https://fake-object-store.invalid/"
  @signature "FAKESIGNATURESENTINEL0123456789abcdef"

  @doc "Starts the store under its module name."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{objects: %{}, signed: %{}, failing: MapSet.new()} end,
      name: __MODULE__
    )
  end

  @doc "The signature every presigned URL carries."
  @spec signature() :: String.t()
  def signature, do: @signature

  @impl ObjectStore
  def presign_put(object_key, %{size: size, sha256: sha256, expires_in: expires_in}) do
    headers = ObjectStore.upload_headers(size, sha256)
    signed = headers |> Map.keys() |> Kernel.++(["host"]) |> Enum.sort() |> Enum.join(";")
    Agent.update(__MODULE__, &put_in(&1, [:signed, object_key], headers))
    {url(object_key, expires_in, signed), headers}
  end

  @impl ObjectStore
  def presign_get(object_key, %{expires_in: expires_in}),
    do: url(object_key, expires_in, "host")

  @impl ObjectStore
  def head(object_key) do
    state = Agent.get(__MODULE__, & &1)

    cond do
      MapSet.member?(state.failing, object_key) -> {:error, :unavailable}
      object = state.objects[object_key] -> {:ok, Map.take(object, [:size, :checksum_sha256])}
      true -> {:error, :not_found}
    end
  end

  @impl ObjectStore
  def delete(object_key) do
    Agent.get_and_update(__MODULE__, fn state ->
      cond do
        MapSet.member?(state.failing, object_key) -> {{:error, :unavailable}, state}
        Map.has_key?(state.objects, object_key) -> {:ok, delete_object(state, object_key)}
        true -> {{:error, :not_found}, state}
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
        put_object(object_key, byte_size(body), checksum)
    end
  end

  @doc "Stores object metadata directly, as if the store had recorded it."
  @spec put_object(String.t(), non_neg_integer(), String.t() | nil) :: :ok
  def put_object(object_key, size, checksum_sha256) do
    object = %{size: size, checksum_sha256: checksum_sha256}
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

  defp delete_object(state, object_key) do
    %{state | objects: Map.delete(state.objects, object_key)}
  end

  defp url(object_key, expires_in, signed_headers) do
    query =
      URI.encode_query([
        {"X-Amz-Algorithm", "AWS4-HMAC-SHA256"},
        {"X-Amz-Expires", Integer.to_string(expires_in)},
        {"X-Amz-SignedHeaders", signed_headers},
        {"X-Amz-Signature", @signature}
      ])

    @host <> object_key <> "?" <> query
  end
end
