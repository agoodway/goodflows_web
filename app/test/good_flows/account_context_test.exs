defmodule GoodFlows.AccountContextTest do
  use GoodFlows.DataCase, async: true

  import GoodFlows.AccountsFixtures

  alias GoodFlows.AccountContext
  alias GoodFlows.Accounts
  alias GoodFlows.Accounts.Account
  alias GoodFlows.Repo

  setup do
    user = user_without_accounts_fixture()
    account = account_fixture(%{name: "Beta Co"})
    account_user_fixture(account, user, :owner)
    %{user: user, account: account}
  end

  describe "create_account/1" do
    test "derives the slug from the name" do
      assert {:ok, %Account{slug: "hello-world-inc"}} =
               Accounts.create_account(%{name: "  Hello, World Inc!"})
    end

    test "rejects duplicate slugs" do
      account_fixture(%{name: "Dup"})
      assert {:error, changeset} = Accounts.create_account(%{name: "Dup"})
      assert "has already been taken" in errors_on(changeset).slug
    end
  end

  describe "list_user_accounts/1" do
    test "returns active memberships sorted by name with roles", %{user: user, account: beta} do
      alpha = account_fixture(%{name: "Alpha Co"})
      account_user_fixture(alpha, user, :member)

      suspended = account_fixture(%{name: "Suspended Co"})
      account_user_fixture(suspended, user)
      suspend!(suspended)

      assert [{%{id: alpha_id}, :member}, {%{id: beta_id}, :owner}] =
               AccountContext.list_user_accounts(user)

      assert alpha_id == alpha.id
      assert beta_id == beta.id
    end
  end

  describe "get_account_for_user/2" do
    test "returns the account for members", %{user: user, account: account} do
      assert {:ok, %Account{id: id}} = AccountContext.get_account_for_user(user, account.id)
      assert id == account.id
    end

    test "hides accounts the user does not belong to", %{account: account} do
      assert {:error, :not_found} =
               AccountContext.get_account_for_user(user_fixture(), account.id)
    end

    test "hides suspended accounts", %{user: user, account: account} do
      suspend!(account)
      assert {:error, :not_found} = AccountContext.get_account_for_user(user, account.id)
    end

    test "handles malformed and missing ids", %{user: user} do
      assert {:error, :not_found} = AccountContext.get_account_for_user(user, "not-a-uuid")
      assert {:error, :not_found} = AccountContext.get_account_for_user(user, nil)
    end
  end

  describe "get_default_account/2" do
    test "prefers last_account_id when still accessible", %{user: user} do
      alpha = account_fixture(%{name: "Alpha Co"})
      account_user_fixture(alpha, user)
      zulu = account_fixture(%{name: "Zulu Co"})
      account_user_fixture(zulu, user)

      assert {:ok, %{id: id}} =
               AccountContext.get_default_account(user, %{"last_account_id" => zulu.id})

      assert id == zulu.id
    end

    test "falls back to the first account when last_account_id is foreign", %{
      user: user,
      account: account
    } do
      foreign = account_fixture()

      assert {:ok, %{id: id}} =
               AccountContext.get_default_account(user, %{"last_account_id" => foreign.id})

      assert id == account.id
    end

    test "errors when the user has no accounts" do
      assert {:error, :no_accounts} =
               AccountContext.get_default_account(user_without_accounts_fixture(), %{})
    end
  end

  defp suspend!(account) do
    account |> Ecto.Changeset.change(status: :suspended) |> Repo.update!()
  end
end
