defmodule GoodFlows.Pools.TransferProtocol do
  @moduledoc """
  Incremental codec for `gf-transfer` protocol v1 (see
  `sprite-transfer/README.md`, the normative wire description).

  A frame is a 4-byte big-endian header length (1 to 8,192), a UTF-8 JSON
  object header, and exactly `len` raw payload bytes (`len` absent means
  0). Every header carries `"v": 1` and a `"type"`: `open`, `ready`,
  `chunk`, `ack`, `finish`, `complete`, `error`, or `collect`.

  `decode/2` takes the bytes received so far and returns the complete
  frames plus the unconsumed remainder. Lengths are checked against the
  limits as soon as the prefix (or header) arrives, before any payload is
  awaited, so a peer cannot make the decoder wait for or buffer more than
  one bounded frame. Callers append each transport fragment to the
  remainder; the remainder never exceeds one header plus one payload.

  `encode/2` writes header keys in the fixed order the helper uses, so
  frames are byte-identical across implementations (the shared fixtures in
  `sprite-transfer/tests/fixtures` check this).
  """

  @version 1
  @max_header 8_192
  @default_max_payload 1_048_576

  # Header key order per frame type (after "v" and "type"); "len" is last.
  @key_order %{
    "open" =>
      ~w(transfer_id direction session_id member_id lease_generation artifact max_payload length sha256),
    "ready" => ~w(transfer_id committed_offset length sha256 max_payload completed),
    "chunk" => ~w(transfer_id offset sha256),
    "ack" => ~w(transfer_id committed_offset),
    "finish" => ~w(transfer_id length sha256),
    "complete" => ~w(transfer_id length sha256 extracted),
    "error" => ~w(code message),
    "collect" => ~w(outputs_present outputs_truncated reports reports_truncated reports_skipped)
  }

  # Frame types that always carry `len` (even 0); control frames never do.
  @payload_types ~w(chunk collect)

  @typedoc "Decoded frame: the header map (string keys) and its payload."
  @type frame :: %{header: map(), payload: binary()}

  @typedoc "Decoder limits: `:max_payload` (default 1 MiB)."
  @type limits :: [max_payload: pos_integer()]

  @type decode_error ::
          :header_too_large
          | :payload_too_large
          | :invalid_header
          | :unsupported_version
          | :length_mismatch

  @doc "The protocol version (1)."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The fixed header size limit (8,192 bytes)."
  @spec max_header() :: pos_integer()
  def max_header, do: @max_header

  @doc "The default and largest payload maximum (1 MiB)."
  @spec default_max_payload() :: pos_integer()
  def default_max_payload, do: @default_max_payload

  @doc """
  Encodes a frame. `header` is a map with atom or string keys (`v` is
  added); `payload` sets `len`. Returns `{:error, reason}` when the header
  or payload exceeds the limits.
  """
  @spec encode(map(), binary(), limits()) :: {:ok, iodata()} | {:error, decode_error()}
  def encode(header, payload \\ "", limits \\ []) when is_map(header) and is_binary(payload) do
    max_payload = max_payload(limits)

    header =
      header
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.drop(["v", "len"])

    type = Map.get(header, "type")
    json = encode_header(header, type, byte_size(payload))

    cond do
      payload != "" and type not in @payload_types -> {:error, :invalid_header}
      byte_size(json) > @max_header -> {:error, :header_too_large}
      byte_size(payload) > max_payload -> {:error, :payload_too_large}
      true -> {:ok, [<<byte_size(json)::32>>, json, payload]}
    end
  end

  @doc "Like `encode/3` but raises on oversize input."
  @spec encode!(map(), binary(), limits()) :: iodata()
  def encode!(header, payload \\ "", limits \\ []) do
    case encode(header, payload, limits) do
      {:ok, iodata} -> iodata
      {:error, reason} -> raise ArgumentError, "cannot encode frame: #{reason}"
    end
  end

  defp encode_header(header, type, len) do
    order = Map.get(@key_order, type, [])
    known = Enum.filter(order, &Map.has_key?(header, &1))
    extra = header |> Map.keys() |> Kernel.--(["type" | order]) |> Enum.sort()

    pairs =
      [{"v", @version}, {"type", type}] ++
        Enum.map(known ++ extra, &{&1, Map.fetch!(header, &1)}) ++
        if(type in @payload_types, do: [{"len", len}], else: [])

    encoded =
      Enum.map(pairs, fn {key, value} -> [Jason.encode!(key), ?:, Jason.encode!(value)] end)

    IO.iodata_to_binary([?{, Enum.intersperse(encoded, ?,), ?}])
  end

  @doc """
  Decodes every complete frame at the front of `buffer`. Returns
  `{:ok, frames, rest}` where `rest` holds an incomplete frame (or nothing),
  or `{:error, reason}` on a malformed or oversized frame. Validation
  happens before waiting for the declared bytes.
  """
  @spec decode(binary(), limits()) :: {:ok, [frame()], binary()} | {:error, decode_error()}
  def decode(buffer, limits \\ []) when is_binary(buffer) do
    decode_frames(buffer, max_payload(limits), [])
  end

  # A negotiated maximum never exceeds the 1 MiB ceiling.
  defp max_payload(limits),
    do: min(Keyword.get(limits, :max_payload, @default_max_payload), @default_max_payload)

  @typedoc """
  Incremental decoder state (`decoder/1`, `feed/2`): buffered fragments and,
  once a header is complete, the parsed header with the payload length it
  still waits for, so a large payload arriving in many fragments is
  neither re-parsed nor re-copied per fragment.
  """
  @opaque decoder :: %{
            max: pos_integer(),
            chunks: [binary()],
            size: non_neg_integer(),
            pending: nil | {map(), non_neg_integer()}
          }

  @doc "A fresh incremental decoder with `limits` (as `decode/2`)."
  @spec decoder(limits()) :: decoder()
  def decoder(limits \\ []),
    do: %{max: max_payload(limits), chunks: [], size: 0, pending: nil}

  @doc "Sets the decoder's payload maximum for frames not yet parsed (clamped to 1 MiB)."
  @spec limit(decoder(), pos_integer()) :: decoder()
  def limit(decoder, max_payload), do: %{decoder | max: max_payload(max_payload: max_payload)}

  @doc "Bytes buffered in `decoder` that do not form a complete frame yet."
  @spec buffered(decoder()) :: non_neg_integer()
  def buffered(%{size: size}), do: size

  @doc """
  Feeds `data` to `decoder`. Returns the frames it completes and the new
  state, or `{:error, reason}` as `decode/2` would, as soon as the
  offending header is complete.
  """
  @spec feed(decoder(), binary()) :: {:ok, [frame()], decoder()} | {:error, decode_error()}
  def feed(decoder, data) when is_binary(data) do
    decoder = %{decoder | chunks: [data | decoder.chunks], size: decoder.size + byte_size(data)}
    drain(decoder, [])
  end

  defp drain(%{pending: {header, len}, size: size} = decoder, acc) when size >= len do
    <<payload::binary-size(len), rest::binary>> = flatten(decoder)
    frame = %{header: header, payload: payload}
    drain(%{decoder | pending: nil, chunks: [rest], size: byte_size(rest)}, [frame | acc])
  end

  defp drain(%{pending: {_header, _len}} = decoder, acc), do: {:ok, Enum.reverse(acc), decoder}

  defp drain(%{pending: nil, size: size} = decoder, acc) when size < 4,
    do: {:ok, Enum.reverse(acc), decoder}

  defp drain(%{pending: nil} = decoder, acc) do
    case flatten(decoder) do
      <<hsize::32, _rest::binary>> when hsize == 0 or hsize > @max_header ->
        {:error, :header_too_large}

      <<hsize::32, json::binary-size(hsize), rest::binary>> ->
        with {:ok, header} <- decode_header(json),
             {:ok, len} <- payload_length(header, decoder.max) do
          drain(%{decoder | pending: {header, len}, chunks: [rest], size: byte_size(rest)}, acc)
        end

      buffer ->
        {:ok, Enum.reverse(acc), %{decoder | chunks: [buffer]}}
    end
  end

  defp flatten(%{chunks: [single]}), do: single
  defp flatten(%{chunks: chunks}), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defp decode_frames(<<size::32, _rest::binary>>, _max, _acc)
       when size == 0 or size > @max_header,
       do: {:error, :header_too_large}

  defp decode_frames(<<size::32, json::binary-size(size), rest::binary>>, max, acc) do
    with {:ok, header} <- decode_header(json),
         {:ok, len} <- payload_length(header, max) do
      case rest do
        <<payload::binary-size(len), rest::binary>> ->
          decode_frames(rest, max, [%{header: header, payload: payload} | acc])

        _incomplete ->
          {:ok, Enum.reverse(acc), <<size::32, json::binary, rest::binary>>}
      end
    end
  end

  defp decode_frames(buffer, _max, acc), do: {:ok, Enum.reverse(acc), buffer}

  # Mirrors the helper's rules: a version other than 1 is
  # `unsupported_version`; a missing or non-string type is invalid.
  defp decode_header(json) do
    case Jason.decode(json) do
      {:ok, %{"v" => @version, "type" => type} = header} when is_binary(type) -> {:ok, header}
      {:ok, %{"v" => @version}} -> {:error, :invalid_header}
      {:ok, %{"v" => _other}} -> {:error, :unsupported_version}
      _other -> {:error, :invalid_header}
    end
  end

  defp payload_length(%{"type" => type} = header, max) do
    case Map.get(header, "len", 0) do
      0 -> {:ok, 0}
      len when not is_integer(len) or len < 0 -> {:error, :invalid_header}
      _len when type not in @payload_types -> {:error, :invalid_header}
      len when len > max -> {:error, :payload_too_large}
      len -> {:ok, len}
    end
  end

  @doc "Lowercase hex SHA-256 of `data`."
  @spec sha256_hex(iodata()) :: String.t()
  def sha256_hex(data), do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)
end
