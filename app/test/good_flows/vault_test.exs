defmodule GoodFlows.VaultTest do
  use ExUnit.Case, async: true

  alias GoodFlows.Vault

  test "decodes a base64 32-byte key" do
    key = :crypto.strong_rand_bytes(32)
    assert Vault.decode_key!(Base.encode64(key)) == key
  end

  test "rejects keys that are not exactly 32 bytes or not base64" do
    for encoded <- [
          Base.encode64(:crypto.strong_rand_bytes(16)),
          Base.encode64(:crypto.strong_rand_bytes(33)),
          "not base64!",
          ""
        ] do
      assert_raise ArgumentError, ~r/32-byte/, fn -> Vault.decode_key!(encoded) end
    end
  end

  test "a missing key names CLOAK_KEY" do
    assert_raise ArgumentError, ~r/CLOAK_KEY/, fn -> Vault.decode_key!(nil) end
  end
end
