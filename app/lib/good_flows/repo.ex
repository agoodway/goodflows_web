defmodule GoodFlows.Repo do
  @moduledoc "Postgres Ecto repository."
  use Ecto.Repo,
    otp_app: :good_flows,
    adapter: Ecto.Adapters.Postgres
end
