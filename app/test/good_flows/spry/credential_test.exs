defmodule GoodFlows.Spry.CredentialTest do
  use GoodFlows.DataCase, async: true

  import GoodFlows.AccountsFixtures

  alias GoodFlows.Spry
  alias GoodFlows.Spry.SpritesCredential

  setup do
    %{account: account_fixture()}
  end

  test "stores the token encrypted", %{account: account} do
    {:ok, credential} = Spry.put_credential(account, %{"token" => "tok_example"})

    %{rows: [[raw]]} =
      Repo.query!("SELECT token FROM sprites_credentials WHERE id = $1", [
        Ecto.UUID.dump!(credential.id)
      ])

    refute raw =~ "tok_example"
    assert Spry.fetch_token(account.id) == {:ok, "tok_example"}
  end

  test "inspect redacts the token", %{account: account} do
    {:ok, credential} = Spry.put_credential(account, %{"token" => "tok_example"})
    refute inspect(credential) =~ "tok_example"
  end

  test "set reports configured with last4", %{account: account} do
    assert Spry.get_credential_status(account) == %{
             configured: false,
             last4: nil,
             updated_at: nil
           }

    {:ok, _} = Spry.put_credential(account, %{"token" => "secret-a1b2"})

    assert %{configured: true, last4: "a1b2", updated_at: %DateTime{}} =
             Spry.get_credential_status(account)
  end

  test "replace keeps one credential with the new token", %{account: account} do
    {:ok, _} = Spry.put_credential(account, %{"token" => "first-1111"})
    {:ok, _} = Spry.put_credential(account, %{"token" => "second-2222"})

    assert Repo.aggregate(SpritesCredential, :count) == 1
    assert Spry.fetch_token(account.id) == {:ok, "second-2222"}
    assert Spry.get_credential_status(account).last4 == "2222"
  end

  test "blank or missing token is rejected", %{account: account} do
    for attrs <- [%{}, %{"token" => ""}, %{"token" => "   "}] do
      assert {:error, cs} = Spry.put_credential(account, attrs)
      assert %{token: [_]} = errors_on(cs)
    end
  end

  test "short tokens have no last4", %{account: account} do
    {:ok, _} = Spry.put_credential(account, %{"token" => "abcd"})
    assert Spry.get_credential_status(account).last4 == nil
  end

  test "delete removes the credential and tolerates absence", %{account: account} do
    {:ok, _} = Spry.put_credential(account, %{"token" => "secret-a1b2"})
    assert Spry.delete_credential(account) == :ok
    assert Spry.get_credential_status(account).configured == false
    assert Spry.fetch_token(account.id) == {:error, :no_credential}
    assert Spry.delete_credential(account) == :ok
  end
end
