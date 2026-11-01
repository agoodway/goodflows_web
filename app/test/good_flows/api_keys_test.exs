defmodule GoodFlows.ApiKeysTest do
  use GoodFlows.DataCase, async: true

  import GoodFlows.AccountsFixtures

  alias GoodFlows.Accounts
  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.Repo

  setup do
    user = user_fixture()
    account = account_fixture()
    %{account: account, account_user: account_user_fixture(account, user)}
  end

  describe "create_api_key/2" do
    test "stores only the prefix and hash of the token", %{account_user: account_user} do
      {:ok, {api_key, token}} =
        Accounts.create_api_key(account_user, %{name: "CI", type: :private})

      assert "sk_" <> _ = token
      assert api_key.token_prefix == String.slice(token, 0, 12)
      assert api_key.token_hash == ApiKey.hash_token(token)
      refute api_key.token_hash =~ token
    end

    test "defaults to a public key", %{account_user: account_user} do
      {_api_key, token} = api_key_fixture(account_user)
      assert "pk_" <> _ = token
    end

    test "never takes account_user_id from attrs", %{account_user: account_user} do
      other = account_user_fixture(account_fixture(), user_fixture())

      {:ok, {api_key, _}} =
        Accounts.create_api_key(account_user, %{"name" => "x", "account_user_id" => other.id})

      assert api_key.account_user_id == account_user.id
    end

    test "validates name and future expiry", %{account_user: account_user} do
      past = DateTime.add(DateTime.utc_now(), -60)

      assert {:error, changeset} =
               Accounts.create_api_key(account_user, %{name: " ", expires_at: past})

      assert %{name: ["can't be blank"], expires_at: ["must be in the future"]} =
               errors_on(changeset)
    end
  end

  describe "verify_api_token/1" do
    test "returns the key with membership, user, and account", %{
      account_user: account_user,
      account: account
    } do
      {api_key, token} = api_key_fixture(account_user)

      assert {:ok, verified} = Accounts.verify_api_token(token)
      assert verified.id == api_key.id
      assert verified.account_user.account.id == account.id
      assert verified.account_user.user.id == account_user.user_id
    end

    test "rejects unknown, revoked, and expired tokens", %{account_user: account_user} do
      assert {:error, :invalid_token} = Accounts.verify_api_token("pk_nope")

      {api_key, token} = api_key_fixture(account_user)
      {:ok, _} = Accounts.revoke_api_key(api_key)
      assert {:error, :invalid_token} = Accounts.verify_api_token(token)

      {api_key, token} = api_key_fixture(account_user)
      api_key |> Ecto.Changeset.change(expires_at: ~U[2000-01-01 00:00:00Z]) |> Repo.update!()
      assert {:error, :invalid_token} = Accounts.verify_api_token(token)
    end

    test "rejects keys of unconfirmed users", %{account: account} do
      account_user = account_user_fixture(account, unconfirmed_user_fixture())
      {_api_key, token} = api_key_fixture(account_user)
      assert {:error, :invalid_token} = Accounts.verify_api_token(token)
    end

    test "rejects keys of suspended accounts", %{account_user: account_user, account: account} do
      {_api_key, token} = api_key_fixture(account_user)
      account |> Ecto.Changeset.change(status: :suspended) |> Repo.update!()
      assert {:error, :invalid_token} = Accounts.verify_api_token(token)
    end
  end

  describe "touch_api_key/1" do
    test "sets last_used_at, then throttles writes", %{account_user: account_user} do
      {api_key, _} = api_key_fixture(account_user)

      {:ok, touched} = Accounts.touch_api_key(api_key)
      assert touched.last_used_at

      recent = %{touched | last_used_at: DateTime.add(touched.last_used_at, -10)}
      assert {:ok, ^recent} = Accounts.touch_api_key(recent)
    end
  end

  describe "list_api_keys/1 and get_api_key/2" do
    test "only see the membership's own keys", %{account_user: account_user} do
      {mine, _} = api_key_fixture(account_user)
      other = account_user_fixture(account_fixture(), user_fixture())
      {theirs, _} = api_key_fixture(other)

      assert [%{id: id}] = Accounts.list_api_keys(account_user)
      assert id == mine.id
      assert Accounts.get_api_key(account_user, mine.id)
      refute Accounts.get_api_key(account_user, theirs.id)
      refute Accounts.get_api_key(account_user, "not-a-uuid")
    end
  end
end
