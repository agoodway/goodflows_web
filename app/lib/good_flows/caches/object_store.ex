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

  @typedoc """
  What `head/1` reports: the length, the base64 SHA-256 the store recorded
  (none for a multipart object), and the ETag without quotes.
  """
  @type object_info :: %{
          size: non_neg_integer(),
          checksum_sha256: String.t() | nil,
          etag: String.t() | nil
        }

  @typedoc "An uploaded part as the store lists it (ETag without quotes)."
  @type part :: %{number: pos_integer(), etag: String.t(), size: non_neg_integer()}

  @doc """
  Presigns a PUT of `object_key` for an archive of `:size` bytes whose
  digest is `:sha256` (64 lowercase hex), valid for `:expires_in` seconds.
  Returns the URL and the headers signed into it.
  """
  @callback presign_put(object_key :: String.t(), opts :: map()) ::
              {String.t(), upload_headers()}

  @doc "Presigns a GET of `object_key`, valid for `:expires_in` seconds."
  @callback presign_get(object_key :: String.t(), opts :: map()) :: String.t()

  @doc "Reads an object's length, recorded SHA-256 (checksum mode enabled) and ETag."
  @callback head(object_key :: String.t()) ::
              {:ok, object_info()} | {:error, :not_found} | {:error, term()}

  @doc "Deletes an object. `{:error, :not_found}` means it is already gone."
  @callback delete(object_key :: String.t()) :: :ok | {:error, :not_found} | {:error, term()}

  @doc """
  Starts a multipart upload of `object_key` (`content-type:
  application/gzip`) and returns the store's upload id.
  """
  @callback create_multipart(object_key :: String.t()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Presigns the PUT of part `number` of upload `upload_id`, of `:size` bytes
  whose MD5 is `:md5` (padded base64), valid for `:expires_in` seconds.
  Returns the URL and the headers signed into it (`part_headers/2`). Local
  signing; no store request.
  """
  @callback presign_part(
              object_key :: String.t(),
              upload_id :: String.t(),
              number :: pos_integer(),
              opts :: map()
            ) :: {String.t(), upload_headers()}

  @doc """
  Lists every uploaded part of `upload_id` in part order.
  `{:error, :not_found}` when the upload was completed or aborted.
  """
  @callback list_parts(object_key :: String.t(), upload_id :: String.t()) ::
              {:ok, [part()]} | {:error, :not_found} | {:error, term()}

  @doc """
  Completes `upload_id` from the given `{number, etag}` parts.
  `{:error, :not_found}` when the upload no longer exists (completed or
  aborted), `{:error, {:rejected, code}}` when the store refuses the parts
  (an S3 error code such as `InvalidPart`).
  """
  @callback complete_multipart(
              object_key :: String.t(),
              upload_id :: String.t(),
              parts :: [{pos_integer(), String.t()}]
            ) :: :ok | {:error, :not_found} | {:error, {:rejected, String.t()}} | {:error, term()}

  @doc """
  Aborts `upload_id`; later part PUTs fail. `{:error, :not_found}` means the
  upload is already gone.
  """
  @callback abort_multipart(object_key :: String.t(), upload_id :: String.t()) ::
              :ok | {:error, :not_found} | {:error, term()}

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

  @doc """
  The headers a PUT of a `size`-byte part whose MD5 is `md5` (padded
  base64) must send: `content-length` and `content-md5`.
  """
  @spec part_headers(pos_integer(), String.t()) :: upload_headers()
  def part_headers(size, md5) do
    %{"content-length" => Integer.to_string(size), "content-md5" => md5}
  end

  @doc """
  The ETag of a multipart object whose parts have the base64 MD5s `md5s`:
  the hex MD5 of the concatenated binary MD5s, then `-` and the count.
  """
  @spec multipart_etag([String.t()]) :: String.t()
  # MD5 is what S3 defines the multipart ETag as, not a security choice:
  # only a key that may write the scope can declare the part MD5s.
  # sobelow_skip ["Crypto.WeakHash"]
  def multipart_etag(md5s) do
    digest = md5s |> Enum.map(&Base.decode64!/1) |> then(&:crypto.hash(:md5, &1))
    Base.encode16(digest, case: :lower) <> "-" <> Integer.to_string(length(md5s))
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

  @doc "See the `c:create_multipart/1` callback."
  @spec create_multipart(String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_multipart(object_key), do: adapter().create_multipart(object_key)

  @doc "See the `c:presign_part/4` callback."
  @spec presign_part(String.t(), String.t(), pos_integer(), map()) ::
          {String.t(), upload_headers()}
  def presign_part(object_key, upload_id, number, opts),
    do: adapter().presign_part(object_key, upload_id, number, opts)

  @doc "See the `c:list_parts/2` callback."
  @spec list_parts(String.t(), String.t()) ::
          {:ok, [part()]} | {:error, :not_found} | {:error, term()}
  def list_parts(object_key, upload_id), do: adapter().list_parts(object_key, upload_id)

  @doc "See the `c:complete_multipart/3` callback."
  @spec complete_multipart(String.t(), String.t(), [{pos_integer(), String.t()}]) ::
          :ok | {:error, :not_found} | {:error, {:rejected, String.t()}} | {:error, term()}
  def complete_multipart(object_key, upload_id, parts),
    do: adapter().complete_multipart(object_key, upload_id, parts)

  @doc "See the `c:abort_multipart/2` callback."
  @spec abort_multipart(String.t(), String.t()) :: :ok | {:error, :not_found} | {:error, term()}
  def abort_multipart(object_key, upload_id), do: adapter().abort_multipart(object_key, upload_id)

  defp adapter, do: Keyword.get(config(), :adapter, GoodFlows.Caches.ObjectStore.S3)
end
