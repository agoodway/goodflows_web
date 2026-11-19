defmodule GoodFlows.Caches.ObjectStore do
  @moduledoc """
  The S3-compatible bucket that holds cache archives (Cloudflare R2 in
  production, MinIO locally).

  The app never streams an archive. It hands out presigned URLs and checks
  and deletes objects. The implementation is
  `config :good_flows, GoodFlows.Caches.ObjectStore, adapter: …`
  (`GoodFlows.Caches.ObjectStore.S3`, or the in-memory
  `GoodFlows.Caches.ObjectStore.Fake` in tests). Caches are enabled only
  when `:bucket` is set.

  Presigned URLs are bearer credentials: implementations and their callers
  never log them.
  """

  @typedoc "The headers a presigned PUT must send, signed into its URL."
  @type upload_headers :: %{String.t() => String.t()}

  @typedoc "What `head/1` reports: the length and the base64 SHA-256 the store recorded."
  @type object_info :: %{size: non_neg_integer(), checksum_sha256: String.t() | nil}

  @doc """
  Presigns a PUT of `object_key` for an archive of `:size` bytes whose
  digest is `:sha256` (64 lowercase hex), valid for `:expires_in` seconds.
  Returns the URL and the headers signed into it.
  """
  @callback presign_put(object_key :: String.t(), opts :: map()) ::
              {String.t(), upload_headers()}

  @doc "Presigns a GET of `object_key`, valid for `:expires_in` seconds."
  @callback presign_get(object_key :: String.t(), opts :: map()) :: String.t()

  @doc "Reads an object's length and recorded SHA-256 (checksum mode enabled)."
  @callback head(object_key :: String.t()) ::
              {:ok, object_info()} | {:error, :not_found} | {:error, term()}

  @doc "Deletes an object. `{:error, :not_found}` means it is already gone."
  @callback delete(object_key :: String.t()) :: :ok | {:error, :not_found} | {:error, term()}

  @doc "Whether a cache bucket is configured."
  @spec configured?() :: boolean()
  def configured?, do: config()[:bucket] not in [nil, ""]

  @doc "The configured store settings."
  @spec config() :: keyword()
  def config, do: Application.get_env(:good_flows, __MODULE__, [])

  @doc """
  The headers a PUT of `size` bytes with digest `sha256` must send:
  `content-length`, `content-type: application/gzip`, and
  `x-amz-checksum-sha256` (the base64 of the digest).
  """
  @spec upload_headers(pos_integer(), String.t()) :: upload_headers()
  def upload_headers(size, sha256) do
    %{
      "content-length" => Integer.to_string(size),
      "content-type" => "application/gzip",
      "x-amz-checksum-sha256" => sha256 |> Base.decode16!(case: :lower) |> Base.encode64()
    }
  end

  @doc "See the `c:presign_put/2` callback."
  @spec presign_put(String.t(), map()) :: {String.t(), upload_headers()}
  def presign_put(object_key, opts), do: adapter().presign_put(object_key, opts)

  @doc "See the `c:presign_get/2` callback."
  @spec presign_get(String.t(), map()) :: String.t()
  def presign_get(object_key, opts), do: adapter().presign_get(object_key, opts)

  @doc "See the `c:head/1` callback."
  @spec head(String.t()) :: {:ok, object_info()} | {:error, :not_found} | {:error, term()}
  def head(object_key), do: adapter().head(object_key)

  @doc "See the `c:delete/1` callback."
  @spec delete(String.t()) :: :ok | {:error, :not_found} | {:error, term()}
  def delete(object_key), do: adapter().delete(object_key)

  defp adapter, do: Keyword.get(config(), :adapter, GoodFlows.Caches.ObjectStore.S3)
end
