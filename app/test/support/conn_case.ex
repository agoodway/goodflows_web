defmodule GoodFlowsWeb.ConnCase do
  @moduledoc """
  Test case template for tests that need a `Plug.Conn`.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use GoodFlowsWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias GoodFlows.Accounts.Scope

  using do
    quote do
      # The default endpoint for testing
      @endpoint GoodFlowsWeb.Endpoint

      use GoodFlowsWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import GoodFlowsWeb.ConnCase
    end
  end

  setup tags do
    GoodFlows.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Setup helper that registers and logs in users.

      setup :register_and_log_in_user

  It stores an updated connection and a registered user in the
  test context.
  """
  def register_and_log_in_user(%{conn: conn} = context) do
    user = GoodFlows.AccountsFixtures.user_fixture()
    scope = Scope.for_user(user)

    opts =
      context
      |> Map.take([:token_authenticated_at])
      |> Enum.into([])

    %{conn: log_in_user(conn, user, opts), user: user, scope: scope}
  end

  @doc """
  Setup helper for JSON API tests: creates an account owned by a new user
  with a private (`sk_`) and a public (`pk_`) key, plus a second account
  with its own private key.

      setup :api_setup

  Adds `account`, `other_account`, `sk_conn`, `pk_conn`, and `other_conn`
  (connections with the Bearer header and JSON accept header set), the
  owner's private key record as `sk_key`, and `member_sk_conn`: a private
  key of a second user who is a plain `:member` of `account`.
  """
  def api_setup(_context) do
    {account, {sk_key, sk}, pk} = api_account()
    {other_account, {_other_key, other_sk}, _other_pk} = api_account()

    member = GoodFlows.AccountsFixtures.user_fixture()
    member_au = GoodFlows.AccountsFixtures.account_user_fixture(account, member, :member)

    {_key, member_sk} =
      GoodFlows.AccountsFixtures.api_key_fixture(member_au, %{type: :private})

    %{
      account: account,
      other_account: other_account,
      sk_key: sk_key,
      sk_conn: api_conn(sk),
      pk_conn: api_conn(pk),
      other_conn: api_conn(other_sk),
      member_sk_conn: api_conn(member_sk)
    }
  end

  defp api_account do
    user = GoodFlows.AccountsFixtures.user_fixture()

    {:ok, account} =
      GoodFlows.Accounts.create_account(user, %{
        name: "Acct #{System.unique_integer([:positive])}"
      })

    account_user = GoodFlows.Accounts.get_account_user(user, account)
    {sk_key, sk} = GoodFlows.AccountsFixtures.api_key_fixture(account_user, %{type: :private})
    {_key, pk} = GoodFlows.AccountsFixtures.api_key_fixture(account_user, %{type: :public})
    {account, {sk_key, sk}, pk}
  end

  @doc "Builds a JSON API connection authenticated with `token`."
  def api_conn(token) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
  end

  @doc """
  Logs the given `user` into the `conn`.

  It returns an updated `conn`.
  """
  def log_in_user(conn, user, opts \\ []) do
    token = GoodFlows.Accounts.generate_user_session_token(user)

    maybe_set_token_authenticated_at(token, opts[:token_authenticated_at])

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp maybe_set_token_authenticated_at(_token, nil), do: nil

  defp maybe_set_token_authenticated_at(token, authenticated_at) do
    GoodFlows.AccountsFixtures.override_token_authenticated_at(token, authenticated_at)
  end
end
