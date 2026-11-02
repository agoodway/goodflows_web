defmodule GoodFlows.Pools.Archive do
  @moduledoc """
  Preflight validation of an uploaded workspace (`tar` + gzip) before any
  member is touched.

  The archive is decompressed in bounded chunks and only tar headers (and
  bounded GNU long-name and pax metadata) are kept; file data is counted,
  never buffered. Validation enforces, against `GoodFlows.Pools.Config`:

    * the expanded byte limit and the entry limit (`{:error, {:too_large, _}}`,
      answered `413`), and the wall-clock deadline (also `413`)
    * entry confinement (`{:error, {:invalid, _}}`, answered `422`): no
      absolute paths, no `..` segments, no NUL bytes; only regular files,
      directories, symbolic links, and hard links; no global pax header
      overriding entry paths, link targets, or sizes; no entry written through
      a path that is a symbolic link anywhere in the archive; no path that
      appears twice with different types (or a link appearing twice); hard
      links only to earlier regular files; and every symbolic link, resolved
      component by component through the archive's final set of links
      (including chains, at most 40 hops), must stay inside the workspace
    * a well-formed gzip stream and tar headers (checksums verified)

  The helper inside the Sprite enforces the same rules again before
  extracting.
  """

  alias GoodFlows.Pools.Config

  @read_bytes 65_536
  @meta_max 65_536
  @max_hops 40

  @typedoc "Expanded-byte and entry limits and the validation deadline (ms)."
  @type limits :: %{
          max_expanded: pos_integer(),
          max_entries: pos_integer(),
          timeout_ms: pos_integer()
        }

  @doc "Limits from the pool configuration."
  @spec limits() :: limits()
  def limits do
    %{
      max_expanded: Config.workspace_max_expanded_bytes(),
      max_entries: Config.workspace_max_entries(),
      timeout_ms: Config.archive_validation_timeout_ms()
    }
  end

  @doc "Validates the archive at `path`."
  @spec validate(Path.t(), limits()) :: :ok | {:error, {:invalid | :too_large, String.t()}}
  # Called with the session's workspace upload in the node spool (server-named path).
  # sobelow_skip ["Traversal.FileModule"]
  def validate(path, limits) do
    deadline = System.monotonic_time(:millisecond) + limits.timeout_ms
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 31)
      {:ok, file} = File.open(path, [:read, :binary, :raw])

      try do
        state = %{
          limits: limits,
          deadline: deadline,
          buffer: "",
          mode: :header,
          pending: %{},
          entries: 0,
          expanded: 0,
          types: %{},
          links: %{},
          ever_links: MapSet.new(),
          zeros: 0
        }

        with {:ok, state} <- read_loop(file, z, state) do
          finish(state)
        end
      after
        File.close(file)
      end
    rescue
      ErlangError ->
        {:error, {:invalid, "the workspace is not a valid gzip-compressed tar archive"}}
    catch
      {:archive, reason} -> {:error, reason}
    after
      :zlib.close(z)
    end
  end

  defp read_loop(file, z, state) do
    check_deadline!(state)

    case IO.binread(file, @read_bytes) do
      :eof ->
        if state.mode == :done or (state.mode == :header and state.buffer == ""),
          do: {:ok, state},
          else: throw({:archive, {:invalid, "the archive is truncated"}})

      {:error, _reason} ->
        throw({:archive, {:invalid, "the archive could not be read"}})

      data ->
        state = inflate(z, data, state)
        read_loop(file, z, state)
    end
  end

  defp inflate(z, data, state) do
    case :zlib.safeInflate(z, data) do
      {:continue, out} -> z |> inflate("", feed(state, IO.iodata_to_binary(out)))
      {:finished, out} -> feed(state, IO.iodata_to_binary(out))
      {:need_dictionary, _, _} -> throw({:archive, {:invalid, "unsupported gzip stream"}})
    end
  end

  defp feed(%{mode: :done} = state, _data), do: state
  defp feed(state, ""), do: state
  defp feed(state, data), do: parse(%{state | buffer: state.buffer <> data})

  defp parse(%{mode: :done} = state), do: %{state | buffer: ""}

  defp parse(%{mode: :header, buffer: <<block::binary-size(512), rest::binary>>} = state) do
    state = %{state | buffer: rest}

    if block == :binary.copy(<<0>>, 512) do
      zeros = state.zeros + 1

      parse(
        if zeros >= 2, do: %{state | mode: :done, zeros: zeros}, else: %{state | zeros: zeros}
      )
    else
      check_deadline!(state)
      state |> header(block) |> parse()
    end
  end

  defp parse(%{mode: {:skip, n}, buffer: buffer} = state) when byte_size(buffer) >= n do
    <<_::binary-size(n), rest::binary>> = buffer
    parse(%{state | mode: :header, buffer: rest})
  end

  defp parse(%{mode: {:skip, n}, buffer: buffer} = state),
    do: %{state | mode: {:skip, n - byte_size(buffer)}, buffer: ""}

  defp parse(%{mode: {:meta, kind, size, padded}, buffer: buffer} = state)
       when byte_size(buffer) >= padded do
    <<data::binary-size(size), _pad::binary-size(padded - size), rest::binary>> = buffer
    state = %{state | buffer: rest, mode: :header}
    parse(apply_meta(state, kind, data))
  end

  defp parse(state), do: state

  defp header(state, block) do
    <<name::binary-size(100), _mode::binary-size(8), _uid::binary-size(8), _gid::binary-size(8),
      size::binary-size(12), _mtime::binary-size(12), chksum::binary-size(8),
      type::binary-size(1), linkname::binary-size(100), magic::binary-size(6),
      _version::binary-size(2), _uname::binary-size(32), _gname::binary-size(32),
      _devmajor::binary-size(8), _devminor::binary-size(8), prefix::binary-size(155),
      _pad::binary>> = block

    verify_checksum!(block, chksum)
    size = parse_size!(size)
    padded = padded(size)

    case type do
      t when t in ["L", "K", "x", "g"] ->
        if size > @meta_max, do: throw({:archive, {:invalid, "archive metadata is too large"}})
        %{state | mode: {:meta, t, size, padded}}

      _entry ->
        path =
          state.pending[:path] ||
            join_name(cstring(prefix), cstring(name), String.starts_with?(magic, "ustar"))

        link = state.pending[:linkpath] || cstring(linkname)
        size = state.pending[:size] || size
        padded = padded(size)
        state = entry(%{state | pending: %{}}, type, path, link, size)
        %{state | mode: if(padded == 0, do: :header, else: {:skip, padded})}
    end
  end

  defp apply_meta(state, "L", data), do: put_pending(state, :path, cstring(data))
  defp apply_meta(state, "K", data), do: put_pending(state, :linkpath, cstring(data))

  defp apply_meta(state, "x", data) do
    data
    |> pax_records()
    |> Enum.reduce(state, fn
      {"path", value}, acc -> put_pending(acc, :path, value)
      {"linkpath", value}, acc -> put_pending(acc, :linkpath, value)
      {"size", value}, acc -> put_pending(acc, :size, parse_decimal!(value))
      _other, acc -> acc
    end)
  end

  # A global pax header applies to every later entry; like the helper, it
  # may not override entry paths, link targets, or sizes.
  defp apply_meta(state, "g", data) do
    for {key, _value} <- pax_records(data),
        key in ["path", "linkpath", "size"],
        do: reject!("a global pax header overrides entry fields")

    state
  end

  defp put_pending(state, key, value), do: %{state | pending: Map.put(state.pending, key, value)}

  defp pax_records(""), do: []

  defp pax_records(data) do
    with [len_text, _] <- String.split(data, " ", parts: 2),
         {len, ""} when len > 0 <- Integer.parse(len_text),
         <<record::binary-size(len), rest::binary>> <- data,
         [_len, kv] <- String.split(record, " ", parts: 2),
         [key, value] <- String.split(String.trim_trailing(kv, "\n"), "=", parts: 2) do
      [{key, value} | pax_records(rest)]
    else
      _ -> throw({:archive, {:invalid, "malformed pax header"}})
    end
  end

  defp entry(state, type, path, link, size) do
    segments = normalize_path!(path)
    kind = kind!(type)
    entries = state.entries + 1
    expanded = state.expanded + if(kind == :file, do: size, else: 0)
    check_limits!(state.limits, entries, expanded)

    key = Enum.join(segments, "/")
    check_type_conflict!(state.types, key, kind, path)

    state = %{state | entries: entries, expanded: expanded}
    record_entry(state, kind, segments, key, path, link)
  end

  defp check_limits!(limits, entries, _expanded) when entries > limits.max_entries,
    do: throw({:archive, {:too_large, "the archive has more than #{limits.max_entries} entries"}})

  defp check_limits!(limits, _entries, expanded) when expanded > limits.max_expanded,
    do: throw({:archive, {:too_large, "the archive expands beyond #{limits.max_expanded} bytes"}})

  defp check_limits!(_limits, _entries, _expanded), do: :ok

  defp check_type_conflict!(types, key, kind, path) do
    case Map.get(types, key) do
      nil -> :ok
      ^kind when kind in [:dir, :file] -> :ok
      _other -> reject!("#{path} appears twice with different types")
    end
  end

  defp record_entry(state, :symlink, segments, key, path, link) do
    if String.starts_with?(link, "/"), do: reject!("symbolic link #{path} is absolute")

    if link == "" or String.contains?(link, <<0>>),
      do: reject!("symbolic link #{path} is invalid")

    target = {Enum.drop(segments, -1), String.split(link, "/")}

    %{
      state
      | types: Map.put(state.types, key, :symlink),
        links: Map.put(state.links, key, target),
        ever_links: MapSet.put(state.ever_links, key)
    }
    |> record_segments(segments)
  end

  defp record_entry(state, :hardlink, segments, key, path, link) do
    target = normalize_path!(link) |> Enum.join("/")

    if Map.get(state.types, target) != :file,
      do: reject!("hard link #{path} does not point to an earlier regular file")

    state |> record_segments(segments) |> put_type(key, :file)
  end

  defp record_entry(state, kind, segments, key, _path, _link) do
    state |> record_segments(segments) |> put_type(key, kind)
  end

  defp put_type(state, key, type), do: %{state | types: Map.put(state.types, key, type)}

  # Remembers the entry's parents so a later link over them is caught in finish/1.
  defp record_segments(state, segments) do
    parents =
      for n <- 1..(length(segments) - 1)//1, into: MapSet.new() do
        segments |> Enum.take(n) |> Enum.join("/")
      end

    Map.update(state, :parents, parents, &MapSet.union(&1, parents))
  end

  defp finish(state) do
    parents = Map.get(state, :parents, MapSet.new())

    for link <- state.ever_links,
        MapSet.member?(parents, link),
        do: reject!("#{link} is a symbolic link that other entries are written through")

    for {key, _target} <- state.links, do: resolve!(state.links, String.split(key, "/"), key)
    :ok
  end

  # Resolves the link at `segments` the way the kernel would, against the
  # archive's final links: `..` pops the real (resolved) path, and each
  # component that is itself a link is replaced by its directory plus its
  # raw target. Popping above the workspace root is an escape. Parents of a
  # link are never links themselves (finish/1 rejects that first).
  defp resolve!(links, segments, name), do: walk(links, [], segments, 0, name)

  defp walk(_links, _resolved, [], _hops, _name), do: :ok

  defp walk(links, resolved, [segment | rest], hops, name) do
    if hops > @max_hops, do: reject!("symbolic link #{name} has too many hops or loops")

    case segment do
      s when s in ["", "."] ->
        walk(links, resolved, rest, hops, name)

      ".." when resolved == [] ->
        reject!("symbolic link #{name} points outside the workspace")

      ".." ->
        walk(links, Enum.drop(resolved, -1), rest, hops, name)

      _ ->
        candidate = resolved ++ [segment]

        case Map.fetch(links, Enum.join(candidate, "/")) do
          {:ok, {dir, target}} -> walk(links, [], dir ++ target ++ rest, hops + 1, name)
          :error -> walk(links, candidate, rest, hops, name)
        end
    end
  end

  defp normalize_path!(path) do
    cond do
      path == "" -> reject!("an entry has an empty path")
      String.contains?(path, <<0>>) -> reject!("an entry path contains NUL")
      String.starts_with?(path, "/") -> reject!("#{path} is an absolute path")
      true -> :ok
    end

    segments = path |> String.split("/") |> Enum.reject(&(&1 in ["", "."]))
    if ".." in segments, do: reject!("#{path} contains a .. segment")
    if segments == [], do: reject!("an entry has an empty path")
    segments
  end

  defp kind!(type) when type in ["0", <<0>>, "7"], do: :file
  defp kind!("5"), do: :dir
  defp kind!("2"), do: :symlink
  defp kind!("1"), do: :hardlink
  defp kind!(type) when type in ["3", "4"], do: reject!("device files are not allowed")
  defp kind!("6"), do: reject!("FIFOs are not allowed")
  defp kind!(_type), do: reject!("unsupported entry type")

  defp reject!(message), do: throw({:archive, {:invalid, message}})

  defp check_deadline!(state) do
    if System.monotonic_time(:millisecond) > state.deadline,
      do: throw({:archive, {:too_large, "the archive could not be validated in time"}})
  end

  defp verify_checksum!(block, chksum) do
    expected = parse_octal(chksum)
    <<head::binary-size(148), _::binary-size(8), tail::binary>> = block
    actual = Enum.sum(:binary.bin_to_list(head <> "        " <> tail))
    if expected != actual, do: throw({:archive, {:invalid, "a tar header checksum is wrong"}})
  end

  defp parse_size!(<<1::1, _::7, _::binary>> = field) do
    <<_::1, value::size(95)>> = field
    value
  end

  defp parse_size!(field) do
    case parse_octal(field) do
      nil -> throw({:archive, {:invalid, "a tar header size is malformed"}})
      value -> value
    end
  end

  defp parse_octal(field) do
    text = field |> cstring() |> String.trim()

    case Integer.parse(text, 8) do
      {value, ""} -> value
      _ when text == "" -> 0
      _ -> nil
    end
  end

  defp parse_decimal!(text) do
    case Integer.parse(text) do
      {value, ""} when value >= 0 -> value
      _ -> throw({:archive, {:invalid, "malformed pax size"}})
    end
  end

  defp cstring(field) do
    case :binary.split(field, <<0>>) do
      [text | _] -> text
    end
  end

  defp join_name("", name, _ustar?), do: name
  defp join_name(prefix, name, true), do: prefix <> "/" <> name
  defp join_name(_prefix, name, false), do: name

  defp padded(size), do: div(size + 511, 512) * 512
end
