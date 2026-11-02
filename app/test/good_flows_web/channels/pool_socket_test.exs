defmodule GoodFlowsWeb.PoolSocketTest do
  use GoodFlowsWeb.ChannelCase, async: false
  use Mimic

  import ExUnit.CaptureLog
  import GoodFlows.AccountsFixtures
  import GoodFlows.PoolsFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Accounts
  alias GoodFlows.Pools.{Events, Sessions}
  alias GoodFlowsWeb.PoolSocket

  setup :set_mimic_global

  setup do
    stub(PgFlow, :enqueue, fn _job, _input -> {:ok, Ecto.UUID.generate()} end)
    user = user_fixture()

    {:ok, account} =
      Accounts.create_account(user, %{name: "Acct #{System.unique_integer([:positive])}"})

    au = Accounts.get_account_user(user, account)
    {key, sk} = api_key_fixture(au, %{type: :private})
    {_pk_key, pk} = api_key_fixture(au, %{type: :public})
    credential_fixture(account)
    project = project_fixture(account, %{"slug" => "app"})
    pool_fixture(project, %{"slug" => "p", "max_members" => 2})

    {:ok, session} =
      Sessions.create(account, project, "p", key, %{
        "max_members" => 1,
        "acquire_timeout_ms" => 60_000
      })

    %{account: account, au: au, key: key, sk: sk, pk: pk, session: session}
  end

  describe "connect/3" do
    test "a private key as the auth token is accepted", ctx do
      assert {:ok, socket} = connect(PoolSocket, %{}, connect_info: %{auth_token: ctx.sk})
      assert socket.assigns.api_key_id == ctx.key.id
      assert socket.assigns.account_id == ctx.account.id
    end

    test "missing, public, unknown, revoked, and expired keys are refused", ctx do
      {expired_key, expired} = api_key_fixture(ctx.au, %{type: :private})

      GoodFlows.Repo.update!(
        Ecto.Changeset.change(expired_key,
          expires_at: DateTime.add(DateTime.utc_now(:second), -60)
        )
      )

      {revoked_key, revoked} = api_key_fixture(ctx.au, %{type: :private})
      {:ok, _} = Accounts.revoke_api_key(revoked_key)

      assert connect(PoolSocket, %{}, connect_info: %{}) == :error
      assert connect(PoolSocket, %{}, connect_info: %{auth_token: nil}) == :error
      assert connect(PoolSocket, %{}, connect_info: %{auth_token: ctx.pk}) == :error
      assert connect(PoolSocket, %{}, connect_info: %{auth_token: "sk_unknown"}) == :error
      assert connect(PoolSocket, %{}, connect_info: %{auth_token: revoked}) == :error
      assert connect(PoolSocket, %{}, connect_info: %{auth_token: expired}) == :error
    end

    test "a token query parameter is refused even with a valid auth token", ctx do
      assert connect(PoolSocket, %{"token" => ctx.sk}, connect_info: %{auth_token: ctx.sk}) ==
               :error
    end

    test "refused while pools are disabled or the node drains", ctx do
      original = Application.get_env(:good_flows, GoodFlows.Pools)
      on_exit(fn -> Application.put_env(:good_flows, GoodFlows.Pools, original) end)
      Application.put_env(:good_flows, GoodFlows.Pools, Keyword.put(original, :enabled, false))
      assert connect(PoolSocket, %{}, connect_info: %{auth_token: ctx.sk}) == :error
      Application.put_env(:good_flows, GoodFlows.Pools, original)

      :persistent_term.put({GoodFlows.Pools.ShutdownDrain, :draining}, true)
      assert connect(PoolSocket, %{}, connect_info: %{auth_token: ctx.sk}) == :error
    end
  end

  describe "real WebSocket transport" do
    setup do
      %{port: serve_endpoint!()}
    end

    defp bearer(token), do: "base64url.bearer.phx." <> Base.encode64(token, padding: false)

    test "the auth token travels in Sec-WebSocket-Protocol and a join works", ctx do
      assert {:upgraded, conn, stream, headers} =
               ws_connect(ctx.port, "/api/v1/socket/websocket?vsn=2.0.0", [
                 "phoenix",
                 bearer(ctx.sk)
               ])

      # The server selects the plain `phoenix` subprotocol, never the token.
      assert {"sec-websocket-protocol", "phoenix"} in headers

      topic = "pool_session:#{ctx.session.id}"
      reply = ws_call(conn, stream, topic, "phx_join", %{}, "1")
      assert %{"status" => "ok", "response" => %{"status" => "waiting"}} = reply

      Events.session_event(ctx.session.id, "member_granted", %{member_id: "m", name: "gfp-x"})

      assert %{"member_id" => "m"} =
               ws_await(conn, stream, fn [_join_ref, nil, ^topic, "member_granted", payload] ->
                 payload
               end)

      :gun.close(conn)
    end

    test "query-string tokens, public keys, and missing tokens are refused unlogged", ctx do
      log =
        capture_log([level: :debug], fn ->
          Logger.configure(level: :debug)

          try do
            assert {:refused, 403, _} =
                     ws_connect(ctx.port, "/api/v1/socket/websocket?vsn=2.0.0&token=#{ctx.sk}", [
                       "phoenix"
                     ])

            assert {:refused, 403, _} =
                     ws_connect(ctx.port, "/api/v1/socket/websocket?vsn=2.0.0", [
                       "phoenix",
                       bearer(ctx.pk)
                     ])

            assert {:refused, 403, _} =
                     ws_connect(ctx.port, "/api/v1/socket/websocket?vsn=2.0.0", ["phoenix"])
          after
            Logger.configure(level: :warning)
          end
        end)

      refute log =~ ctx.sk
      refute log =~ ctx.pk
    end
  end
end
