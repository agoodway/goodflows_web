defmodule GoodFlows.Pools.ArchiveTest do
  use ExUnit.Case, async: true

  import GoodFlows.TarFixtures

  alias GoodFlows.Pools.Archive

  @limits %{max_expanded: 1_000_000, max_entries: 100, timeout_ms: 5_000}

  setup do
    dir = Path.join(System.tmp_dir!(), "archive-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp validate(ctx, bytes, limits \\ @limits) do
    path = Path.join(ctx.dir, "w-#{System.unique_integer([:positive])}.tar.gz")
    File.write!(path, bytes)
    Archive.validate(path, limits)
  end

  test "accepts files, directories, confined links, and nested archives", ctx do
    inner = tar_gz([{:file, "x", "nested"}])

    archive =
      tar_gz([
        {:dir, "src"},
        {:file, "src/main.rs", "fn main() {}"},
        {:file, "./README", "hi"},
        {:symlink, "latest", "src/main.rs"},
        {:symlink, "src/up", "../README"},
        {:symlink, "chain", "latest"},
        {:hardlink, "copy", "src/main.rs"},
        {:file, "vendor/deps.tar.gz", inner},
        {:long_name, String.duplicate("d", 150) <> "/file", "long"}
      ])

    assert validate(ctx, archive) == :ok

    # erl_tar's output (pax/ustar as produced by real tooling) is accepted.
    src = Path.join(ctx.dir, "src")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "a"), "a")
    path = Path.join(ctx.dir, "erl.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(path), [{~c"a", ~c"#{src}/a"}], [:compressed])
    assert Archive.validate(path, @limits) == :ok
  end

  test "accepts the workspace root directory entry that tar -C dir . writes", ctx do
    assert validate(ctx, tar_gz([{:dir, "./"}, {:file, "./README", "hi"}])) == :ok
    assert validate(ctx, tar_gz([{:dir, "."}, {:dir, "./src"}])) == :ok

    src = Path.join(ctx.dir, "ws")
    File.mkdir_p!(Path.join(src, "lib"))
    File.write!(Path.join(src, "lib/a"), "a")
    path = Path.join(ctx.dir, "root.tar.gz")
    {_, 0} = System.cmd("tar", ["-czf", path, "-C", src, "."])
    assert Archive.validate(path, @limits) == :ok
  end

  test "a root path is only accepted for a directory entry", ctx do
    for entries <- [
          [{:file, "./", "x"}],
          [{:symlink, ".", "src"}],
          [{:dir, "src"}, {:file, "f", "x"}, {:hardlink, "h", "./"}]
        ] do
      assert {:error, {:invalid, "an entry has an empty path"}} = validate(ctx, tar_gz(entries)),
             inspect(entries)
    end
  end

  test "rejects escapes, special entries, and link tricks with 422-class errors", ctx do
    hostile = [
      [{:file, "../etc/passwd", "x"}],
      [{:file, "/etc/passwd", "x"}],
      [{:file, "a/../../b", "x"}],
      [{:symlink, "out", "../../etc"}],
      [{:symlink, "abs", "/etc/passwd"}],
      [{:fifo, "pipe"}],
      [{:char, "tty"}],
      [{:hardlink, "h", "../outside"}],
      [{:hardlink, "h", "missing"}],
      # Writing through a link, even a confined one.
      [{:symlink, "d", "src"}, {:dir, "src"}, {:file, "d/x", "x"}],
      # A directory replaced by a link, then written through.
      [{:dir, "a"}, {:symlink, "a", "."}],
      # Duplicate link paths.
      [{:symlink, "l", "x"}, {:symlink, "l", "y"}],
      # A chain completed later: b -> ../.. resolved through a.
      [
        {:dir, "p"},
        {:dir, "p/q"},
        {:symlink, "p/q/b", "../../t"},
        {:symlink, "a", "p/q/b/../.."}
      ],
      # A link loop.
      [{:symlink, "x", "y"}, {:symlink, "y", "x"}]
    ]

    for entries <- hostile do
      assert {:error, {:invalid, message}} = validate(ctx, tar_gz(entries)), inspect(entries)
      assert is_binary(message)
    end
  end

  test "rejects escapes carried in GNU long-name, long-link, and pax headers", ctx do
    hostile = [
      # GNU long name (type L) longer than the 100-byte header field.
      [{:long_name, String.duplicate("d", 120) <> "/../../../evil", "x"}],
      [{:long_name, "../" <> String.duplicate("e", 120), "x"}],
      # GNU long link (type K): the real target is in the extension header.
      [{:long_link, "out", "../../etc/" <> String.duplicate("f", 120)}],
      [{:long_link, "abs", "/etc/" <> String.duplicate("g", 120)}],
      # Local pax headers override the ustar name and link name.
      [{:pax, [{"path", "../evil"}], {:file, "innocent", "x"}}],
      [{:pax, [{"path", "/etc/passwd"}], {:file, "innocent", "x"}}],
      [{:pax, [{"linkpath", "/etc"}], {:symlink, "l", "ok"}}],
      [{:pax, [{"linkpath", "../../etc"}], {:symlink, "l", "ok"}}],
      # Global pax headers may not override entry paths, links, or sizes
      # (the helper rejects them too).
      [{:global_pax, [{"path", "../evil"}]}, {:file, "innocent", "x"}],
      [{:global_pax, [{"linkpath", "/etc"}]}, {:symlink, "l", "ok"}],
      [{:global_pax, [{"size", "0"}]}, {:file, "innocent", "x"}]
    ]

    for entries <- hostile do
      assert {:error, {:invalid, message}} = validate(ctx, tar_gz(entries)), inspect(entries)
      assert is_binary(message)
    end
  end

  test "harmless pax records are accepted, global ones included", ctx do
    archive =
      tar_gz([
        {:global_pax, [{"comment", "built by ci"}]},
        {:pax, [{"path", "src/" <> String.duplicate("h", 120)}], {:file, "short", "x"}},
        {:pax, [{"mtime", "1700000000.5"}], {:file, "b", "y"}}
      ])

    assert validate(ctx, archive) == :ok
  end

  test "malformed archives are invalid", ctx do
    assert {:error, {:invalid, _}} = validate(ctx, "not gzip at all")
    assert {:error, {:invalid, _}} = validate(ctx, :zlib.gzip(:binary.copy(<<1>>, 600)))

    truncated = binary_part(tar([{:file, "a", :binary.copy("x", 2000)}]), 0, 1024)
    assert {:error, {:invalid, _}} = validate(ctx, :zlib.gzip(truncated))
  end

  test "expanded size, entry count, and the deadline are 413-class errors", ctx do
    big =
      tar_gz([
        {:file, "a", :binary.copy(<<0>>, 600_000)},
        {:file, "b", :binary.copy(<<0>>, 600_000)}
      ])

    assert {:error, {:too_large, message}} = validate(ctx, big)
    assert message =~ "expands"

    many = tar_gz(for i <- 1..101, do: {:file, "f#{i}", ""})
    assert {:error, {:too_large, message}} = validate(ctx, many)
    assert message =~ "entries"

    assert {:error, {:too_large, message}} =
             validate(ctx, many, %{@limits | max_entries: 1_000, timeout_ms: -1})

    assert message =~ "in time"
  end

  test "exactly max_entries and max_expanded are accepted; one more is not", ctx do
    limits = %{@limits | max_entries: 3, max_expanded: 1_000}

    exact =
      tar_gz([
        {:dir, "d"},
        {:file, "d/a", :binary.copy("a", 600)},
        {:file, "b", :binary.copy("b", 400)}
      ])

    assert validate(ctx, exact, limits) == :ok

    one_more_entry =
      tar_gz([{:dir, "d"}, {:file, "d/a", "a"}, {:file, "b", "b"}, {:dir, "e"}])

    assert {:error, {:too_large, message}} = validate(ctx, one_more_entry, limits)
    assert message =~ "more than 3 entries"

    one_more_byte =
      tar_gz([{:file, "a", :binary.copy("a", 600)}, {:file, "b", :binary.copy("b", 401)}])

    assert {:error, {:too_large, message}} = validate(ctx, one_more_byte, limits)
    assert message =~ "beyond 1000 bytes"
  end
end
