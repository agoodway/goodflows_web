defmodule GoodFlows.Vault do
  @moduledoc """
  Cloak vault for application-level encryption at rest (AES-256-GCM).

  The key comes from `config :good_flows, GoodFlows.Vault, key: <base64>`,
  which `config/runtime.exs` sets from `CLOAK_KEY` (required in production).
  The key must decode to exactly 32 bytes.
  """
  use Cloak.Vault, otp_app: :good_flows

  @impl GenServer
  def init(config) do
    key = config |> Keyword.get(:key) |> decode_key!()

    config =
      Keyword.put(config, :ciphers,
        default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: key, iv_length: 12}
      )

    {:ok, config}
  end

  @doc "Decodes a base64 encryption key, raising unless it is exactly 32 bytes."
  @spec decode_key!(String.t() | nil) :: binary()
  def decode_key!(encoded) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, <<_::binary-size(32)>> = key} -> key
      _ -> raise ArgumentError, "CLOAK_KEY must be a base64-encoded 32-byte key"
    end
  end

  def decode_key!(nil) do
    raise ArgumentError, "GoodFlows.Vault key is not configured (set CLOAK_KEY)"
  end
end
