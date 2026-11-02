defmodule GoodFlows.Encrypted.Binary do
  @moduledoc "Ecto type for binary/string fields encrypted with `GoodFlows.Vault`."
  use Cloak.Ecto.Binary, vault: GoodFlows.Vault
end
