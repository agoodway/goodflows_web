defmodule GoodFlows.Pools.Credentials do
  @moduledoc """
  Sprites credential handling for pools.

  A credential namespace is identified by an internal fingerprint:
  HMAC-SHA256 of the token keyed with a key derived from the pools'
  `fingerprint_secret` (never a bare hash; production sets it from
  `POOL_FINGERPRINT_SECRET`, falling back to `SECRET_KEY_BASE`, so the web
  secret can rotate without rebuilding every pool). `SpritesCredential` stores no
  organization identity, so any token replacement is a new namespace whose
  members are built separately; sessions are granted only members with
  their own fingerprint. Fingerprints are never exposed.
  """

  alias GoodFlows.Pools.Config
  alias GoodFlows.Spry
  alias Plug.Crypto.KeyGenerator

  @key_cache {__MODULE__, :key}

  @doc "The account's current token and its fingerprint."
  @spec current(Ecto.UUID.t()) ::
          {:ok, %{token: String.t(), fingerprint: binary()}} | {:error, :no_credential}
  def current(account_id) do
    with {:ok, token} <- Spry.fetch_token(account_id) do
      {:ok, %{token: token, fingerprint: fingerprint(token)}}
    end
  end

  @doc "Whether the account has a Sprites credential."
  @spec configured?(Ecto.UUID.t()) :: boolean()
  def configured?(account_id), do: match?({:ok, _}, Spry.fetch_token(account_id))

  @doc "The internal fingerprint of `token`."
  @spec fingerprint(String.t()) :: binary()
  def fingerprint(token) when is_binary(token), do: :crypto.mac(:hmac, :sha256, key(), token)

  defp key do
    case :persistent_term.get(@key_cache, nil) do
      nil ->
        secret =
          Config.fingerprint_secret() ||
            raise ArgumentError,
                  "config :good_flows, GoodFlows.Pools, fingerprint_secret is required for pools"

        key = KeyGenerator.generate(secret, "goodflows pool credential fingerprint")
        :persistent_term.put(@key_cache, key)
        key

      key ->
        key
    end
  end

  @doc "The error message for an account without a Sprites credential."
  @spec missing_message(String.t()) :: String.t()
  def missing_message(action) do
    "A Sprites credential must be configured for this account " <>
      "(PUT /api/v1/sprites-credential) before #{action}"
  end
end
