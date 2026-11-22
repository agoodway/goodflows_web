# Script for populating the database. Run with:
#
#     mix run priv/repo/seeds.exs
#
# Safe to re-run: existing records are reused.

alias GoodFlows.Accounts
alias GoodFlows.Accounts.{Account, AccountUser, User}
alias GoodFlows.Projects
alias GoodFlows.Repo

email = "user@example.com"
password = "password1234password1234"

user =
  Accounts.get_user_by_email(email) ||
    (
      {:ok, user} = Accounts.register_user(%{email: email})

      user
      |> User.password_changeset(%{password: password})
      |> Repo.update!()
      |> User.confirm_changeset()
      |> Repo.update!()
    )

find_or_create_account = fn name ->
  case Repo.get_by(Account, name: name) do
    nil ->
      {:ok, account} = Accounts.create_account(%{name: name})
      account

    account ->
      account
  end
end

ensure_membership = fn account, role ->
  if !Repo.get_by(AccountUser, user_id: user.id, account_id: account.id) do
    {:ok, _} = Accounts.create_account_user(account, user, %{role: role})
  end
end

acme = find_or_create_account.("Acme Corp")
globex = find_or_create_account.("Globex Industries")

ensure_membership.(acme, :owner)
ensure_membership.(globex, :member)

# A project in the account where the user is only a member, so the
# read-only projects views have a row. Acme Corp stays empty on purpose.
case Projects.get_project(globex, "globex-api") do
  {:ok, _project} -> :ok
  {:error, :not_found} -> {:ok, _} = Projects.create_project(globex, %{"slug" => "globex-api"})
end

IO.puts("Seeds created successfully!")
IO.puts("  User: #{email} / #{password}")
IO.puts("  Accounts: Acme Corp (owner), Globex Industries (member)")
IO.puts("  Projects: globex-api (Globex Industries)")
