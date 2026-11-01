defmodule GoodFlows.AccountContext do
  @moduledoc """
  Facade for account-scoped access checks. Every lookup goes through a
  membership check, so callers can pass untrusted account IDs from URLs.
  """

  alias GoodFlows.Accounts
  alias GoodFlows.Accounts.{Account, AccountUser, User}

  @doc "Lists the active accounts `user` belongs to, with the user's role in each."
  @spec list_user_accounts(User.t()) :: [{Account.t(), AccountUser.role()}]
  def list_user_accounts(%User{} = user) do
    Accounts.list_user_accounts(user)
  end

  @doc """
  Fetches an active account by ID only if `user` is a member. Malformed IDs,
  missing accounts, suspended accounts, and non-members all return
  `{:error, :not_found}` so callers cannot probe for account existence.
  """
  @spec get_account_for_user(User.t(), String.t() | nil) ::
          {:ok, Account.t()} | {:error, :not_found}
  def get_account_for_user(_user, nil), do: {:error, :not_found}

  def get_account_for_user(%User{} = user, account_id) when is_binary(account_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(account_id),
         %Account{status: :active} = account <- Accounts.get_account(uuid),
         true <- user_has_access?(user, account) do
      {:ok, account}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Returns whether `user` has a membership in `account`."
  @spec user_has_access?(User.t(), Account.t()) :: boolean()
  def user_has_access?(%User{} = user, %Account{} = account) do
    match?(%AccountUser{}, Accounts.get_account_user(user, account))
  end

  @doc """
  Picks the account to land on: the session's `last_account_id` when the user
  can still access it, otherwise the user's first account by name.
  """
  @spec get_default_account(User.t(), map()) :: {:ok, Account.t()} | {:error, :no_accounts}
  def get_default_account(%User{} = user, session) do
    case get_account_for_user(user, session["last_account_id"]) do
      {:ok, account} -> {:ok, account}
      {:error, :not_found} -> first_account(user)
    end
  end

  defp first_account(user) do
    case list_user_accounts(user) do
      [{account, _role} | _] -> {:ok, account}
      [] -> {:error, :no_accounts}
    end
  end
end
