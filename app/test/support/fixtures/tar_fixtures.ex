defmodule GoodFlows.TarFixtures do
  @moduledoc """
  Builds tar.gz archives entry by entry, including hostile ones (absolute
  paths, `..`, links, special files, duplicates) that normal tools refuse
  to create.

  Entries: `{:file, name, content}`, `{:dir, name}`, `{:symlink, name, target}`,
  `{:hardlink, name, target}`, `{:fifo, name}`, `{:char, name}`, or
  `{:long_name, name, content}` (a GNU long-name file),
  `{:long_link, name, target}` (a symbolic link whose target is carried in a
  GNU long-link header), `{:pax, records, entry}` (a local pax header with
  `records`, a list of `{key, value}`, followed by `entry`), or
  `{:global_pax, records}` (a global pax header).
  """

  @doc "The gzip-compressed archive bytes."
  def tar_gz(entries), do: :zlib.gzip(tar(entries))

  @doc "The uncompressed archive bytes."
  def tar(entries) do
    IO.iodata_to_binary([Enum.map(entries, &entry/1), :binary.copy(<<0>>, 1024)])
  end

  defp entry({:file, name, content}),
    do: [header(name, "0", byte_size(content), ""), pad(content)]

  defp entry({:dir, name}), do: header(name, "5", 0, "")
  defp entry({:symlink, name, target}), do: header(name, "2", 0, target)
  defp entry({:hardlink, name, target}), do: header(name, "1", 0, target)
  defp entry({:fifo, name}), do: header(name, "6", 0, "")
  defp entry({:char, name}), do: header(name, "3", 0, "")

  defp entry({:long_name, name, content}) do
    long = name <> <<0>>

    [
      header("././@LongLink", "L", byte_size(long), ""),
      pad(long),
      entry({:file, String.slice(name, 0, 99), content})
    ]
  end

  defp entry({:long_link, name, target}) do
    long = target <> <<0>>

    [
      header("././@LongLink", "K", byte_size(long), ""),
      pad(long),
      header(name, "2", 0, String.slice(target, 0, 99))
    ]
  end

  defp entry({:pax, records, inner}) do
    data = pax_data(records)
    [header("PaxHeaders/x", "x", byte_size(data), ""), pad(data), entry(inner)]
  end

  defp entry({:global_pax, records}) do
    data = pax_data(records)
    [header("GlobalHead", "g", byte_size(data), ""), pad(data)]
  end

  # Each record is "<length> <key>=<value>\n", the length counting itself.
  defp pax_data(records) do
    Enum.map_join(records, fn {key, value} ->
      body = " #{key}=#{value}\n"
      pax_record_length(byte_size(body), 1) <> body
    end)
  end

  defp pax_record_length(body, digits) do
    total = body + digits

    if String.length(Integer.to_string(total)) == digits,
      do: Integer.to_string(total),
      else: pax_record_length(body, digits + 1)
  end

  defp pad(data) do
    rem = rem(byte_size(data), 512)
    if rem == 0, do: data, else: [data, :binary.copy(<<0>>, 512 - rem)]
  end

  defp header(name, type, size, link) do
    fields = [
      field(name, 100),
      octal(0o644, 8),
      octal(0, 8),
      octal(0, 8),
      octal(size, 12),
      octal(0, 12),
      "        ",
      type,
      field(link, 100),
      "ustar\0",
      "00",
      field("", 32),
      field("", 32),
      octal(0, 8),
      octal(0, 8),
      field("", 155),
      field("", 12)
    ]

    block = IO.iodata_to_binary(fields)
    sum = block |> :binary.bin_to_list() |> Enum.sum()
    <<head::binary-size(148), _::binary-size(8), tail::binary>> = block
    checksum = String.pad_leading(Integer.to_string(sum, 8), 6, "0") <> <<0, 32>>
    head <> checksum <> tail
  end

  defp field(value, size), do: String.pad_trailing(value, size, <<0>>) |> binary_part(0, size)

  defp octal(value, size),
    do: String.pad_leading(Integer.to_string(value, 8), size - 1, "0") <> <<0>>
end
