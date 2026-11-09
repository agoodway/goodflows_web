defmodule GoodFlows.JsonDocumentTest do
  use ExUnit.Case, async: true

  alias GoodFlows.JsonDocument
  alias GoodFlows.TestReports.Document

  defp nested(depth), do: String.duplicate("[", depth) <> String.duplicate("]", depth)

  describe "check_depth/2" do
    test "a custom limit accepts that many containers and rejects one more" do
      assert JsonDocument.check_depth(nested(3), 3) == :ok
      assert JsonDocument.check_depth(nested(4), 3) == {:error, :too_deep}

      assert JsonDocument.check_depth(~s({"a":{"b":1}}), 2) == :ok
      assert JsonDocument.check_depth(~s({"a":{"b":1}}), 1) == {:error, :too_deep}
    end

    test "a limit of zero rejects any container and accepts a scalar" do
      assert JsonDocument.check_depth("{}", 0) == {:error, :too_deep}
      assert JsonDocument.check_depth("[]", 0) == {:error, :too_deep}
      assert JsonDocument.check_depth("1", 0) == :ok
      assert JsonDocument.check_depth("\"[{\"", 0) == :ok
    end

    test "brackets inside strings, including after an escaped quote, do not count" do
      inside = ~s({"a": "#{String.duplicate("[{", 20)} \\" #{String.duplicate("[", 20)}"})
      assert JsonDocument.check_depth(inside, 1) == :ok

      escaped_backslash = ~s(["\\\\", #{nested(2)}])
      assert JsonDocument.check_depth(escaped_backslash, 2) == {:error, :too_deep}
      assert JsonDocument.check_depth(escaped_backslash, 3) == :ok
    end

    test "the test-report cap stays a delegate to depth 16" do
      assert Document.max_depth() == 16
      assert Document.check_depth(nested(16)) == JsonDocument.check_depth(nested(16), 16)
      assert Document.check_depth(nested(17)) == {:error, :too_deep}
      assert JsonDocument.check_depth(nested(17), 17) == :ok
    end
  end

  describe "decode/1 and normalize/1" do
    test "duplicate keys, NUL and integers past 2^53-1 are fixed errors" do
      {:ok, dup} = JsonDocument.decode(~s({"a":1,"a":2}))
      assert JsonDocument.normalize(dup) == {:error, [{[], "has a duplicate key"}]}

      {:ok, nul_key} = JsonDocument.decode(~s({"a\\u0000":1}))

      assert JsonDocument.normalize(nul_key) ==
               {:error, [{[], "must not contain NUL characters"}]}

      {:ok, nul_string} = JsonDocument.decode(~s({"workflow":"a\\u0000b"}))

      assert JsonDocument.normalize(nul_string) ==
               {:error, [{["workflow"], "must not contain NUL characters"}]}

      too_big = JsonDocument.max_integer() + 1
      {:ok, big} = JsonDocument.decode(~s({"n":#{too_big}}))
      assert JsonDocument.normalize(big) == {:error, [{["n"], "is out of range"}]}

      {:ok, at_max} = JsonDocument.decode(~s({"n":#{JsonDocument.max_integer()}}))
      assert {:ok, %{"n" => _}} = JsonDocument.normalize(at_max)
    end

    test "a non-integer number passes normalize and -0 decodes as a float" do
      {:ok, one} = JsonDocument.decode(~s({"duration_ms":1.0}))
      assert {:ok, %{"duration_ms" => 1.0}} = JsonDocument.normalize(one)

      assert {:ok, [-0.0]} = JsonDocument.decode("[-0]")
    end

    test "malformed JSON is rejected without an echoed value" do
      assert JsonDocument.decode("{") == {:error, :malformed_json}
    end
  end

  describe "digest/1 and render_path/1" do
    test "key order does not change the digest and array order does" do
      assert {:ok, left} = decode_normalized(~s({"b":1,"a":[2,3]}))
      assert {:ok, right} = decode_normalized(~s({"a":[2,3],"b":1}))
      assert left == %{"b" => 1, "a" => [2, 3]}

      assert JsonDocument.digest(left) == JsonDocument.digest(right)
      refute JsonDocument.digest([1, 2]) == JsonDocument.digest([2, 1])
    end

    test "a path stops before a key that is not a contract segment" do
      assert JsonDocument.render_path(["report", "records", 3, "duration_us"]) ==
               "report.records[3].duration_us"

      assert JsonDocument.render_path([]) == "body"
      assert JsonDocument.render_path(["report", "has spaces", "hidden"]) == "report"
    end
  end

  defp decode_normalized(json) do
    {:ok, decoded} = JsonDocument.decode(json)
    JsonDocument.normalize(decoded)
  end
end
