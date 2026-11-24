defmodule GoodFlows.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias GoodFlows.Repo

  alias GoodFlows.Accounts.{Account, AccountUser, ApiKey, User, UserNotifier, UserToken}

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `GoodFlows.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `GoodFlows.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end

  ## Accounts (tenants)

  @doc """
  Lists the active accounts a user belongs to as `{account, role}` tuples,
  sorted by account name.
  """
  def list_user_accounts(%User{} = user) do
    AccountUser
    |> where([au], au.user_id == ^user.id)
    |> join(:inner, [au], a in Account, on: au.account_id == a.id)
    |> where([au, a], a.status == :active)
    |> select([au, a], {a, au.role})
    |> order_by([au, a], asc: a.name)
    |> Repo.all()
  end

  @doc """
  Gets a single account by ID. Returns `nil` when it does not exist.
  """
  def get_account(id) when is_binary(id) do
    Repo.get(Account, id)
  end

  @doc """
  Gets the membership for a user+account pair, or `nil` if the user does not
  belong to the account.
  """
  def get_account_user(%User{} = user, %Account{} = account) do
    Repo.get_by(AccountUser, user_id: user.id, account_id: account.id)
  end

  @doc """
  The email of each membership of the account, as `%{account_user_id =>
  email}`, for pages that name who did something.
  """
  @spec member_emails(Account.t()) :: %{Ecto.UUID.t() => String.t()}
  def member_emails(%Account{id: account_id}) do
    Repo.all(
      from au in AccountUser,
        join: u in assoc(au, :user),
        where: au.account_id == ^account_id,
        select: {au.id, u.email}
    )
    |> Map.new()
  end

  @doc """
  Creates an account.
  """
  def create_account(attrs \\ %{}) do
    %Account{}
    |> Account.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Gets an account by slug, or `nil`."
  def get_account_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Account, slug: slug)
  end

  @doc """
  Creates an account with `user` as its owner, atomically.
  """
  def create_account(%User{} = user, attrs) do
    Repo.transact(fn ->
      with {:ok, account} <- create_account(attrs),
           {:ok, _owner} <- create_account_user(account, user, %{role: :owner}) do
        {:ok, account}
      end
    end)
  end

  @doc "Gets a membership by ID with `:user` and `:account` preloaded. Raises if missing."
  def get_account_user!(id) do
    AccountUser
    |> Repo.get!(id)
    |> Repo.preload([:user, :account])
  end

  @doc "Adds `user` to `account` with `role`."
  def add_user_to_account(%Account{} = account, %User{} = user, role \\ :member) do
    create_account_user(account, user, %{role: role})
  end

  @doc "Removes `user` from `account`, deleting their API keys for it."
  def remove_user_from_account(%Account{} = account, %User{} = user) do
    case get_account_user(user, account) do
      nil -> {:error, :not_found}
      account_user -> Repo.delete(account_user)
    end
  end

  @doc "Changes a member's role."
  def update_account_user_role(%AccountUser{} = account_user, role) do
    account_user
    |> AccountUser.changeset(%{role: role})
    |> Repo.update()
  end

  @doc """
  Adds `user` to `account`. Only `:role` is taken from `attrs`.
  """
  def create_account_user(%Account{} = account, %User{} = user, attrs \\ %{}) do
    %AccountUser{account_id: account.id, user_id: user.id}
    |> AccountUser.changeset(attrs)
    |> Repo.insert()
  end

  ## API keys

  # Skip rewriting last_used_at more often than this, so authenticated API
  # traffic doesn't turn every request into a row update.
  @api_key_touch_interval_seconds 60

  @doc """
  Verifies a raw API token. Returns the active, unexpired key with
  `account_user: [:user, :account]` preloaded, provided the account is active
  and the user has confirmed their email.
  """
  @spec verify_api_token(String.t()) :: {:ok, ApiKey.t()} | {:error, :invalid_token}
  def verify_api_token(token) when is_binary(token) do
    now = DateTime.utc_now()

    query =
      from k in ApiKey,
        join: au in assoc(k, :account_user),
        join: a in assoc(au, :account),
        join: u in assoc(au, :user),
        where: k.token_prefix == ^ApiKey.token_prefix(token),
        where: k.token_hash == ^ApiKey.hash_token(token),
        where: k.status == :active,
        where: is_nil(k.expires_at) or k.expires_at > ^now,
        where: a.status == :active,
        where: not is_nil(u.confirmed_at),
        preload: [account_user: {au, user: u, account: a}]

    case Repo.one(query) do
      nil -> {:error, :invalid_token}
      api_key -> {:ok, api_key}
    end
  end

  @doc """
  Records that the key was just used. Writes at most once per minute per key.
  """
  @spec touch_api_key(ApiKey.t()) :: {:ok, ApiKey.t()} | {:error, Ecto.Changeset.t()}
  def touch_api_key(%ApiKey{} = api_key) do
    now = DateTime.utc_now(:second)

    if api_key.last_used_at &&
         DateTime.diff(now, api_key.last_used_at) < @api_key_touch_interval_seconds do
      {:ok, api_key}
    else
      api_key
      |> Ecto.Changeset.change(last_used_at: now)
      |> Repo.update()
    end
  end

  @doc """
  Creates an API key for an account membership.

  Returns `{:ok, {api_key, raw_token}}`. The raw token is never stored and
  is only available from this return value.
  """
  @spec create_api_key(AccountUser.t(), map()) ::
          {:ok, {ApiKey.t(), String.t()}} | {:error, Ecto.Changeset.t()}
  def create_api_key(%AccountUser{} = account_user, attrs) do
    changeset = ApiKey.changeset(%ApiKey{account_user_id: account_user.id}, attrs)
    token = changeset |> Ecto.Changeset.get_field(:type) |> ApiKey.generate_token()

    changeset
    |> Ecto.Changeset.put_change(:token_prefix, ApiKey.token_prefix(token))
    |> Ecto.Changeset.put_change(:token_hash, ApiKey.hash_token(token))
    |> Repo.insert()
    |> case do
      {:ok, api_key} -> {:ok, {api_key, token}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Returns a changeset for tracking API key form changes."
  @spec change_api_key(ApiKey.t(), map()) :: Ecto.Changeset.t()
  def change_api_key(%ApiKey{} = api_key, attrs \\ %{}) do
    ApiKey.changeset(api_key, attrs)
  end

  @doc "Lists a membership's API keys, newest first."
  @spec list_api_keys(AccountUser.t()) :: [ApiKey.t()]
  def list_api_keys(%AccountUser{} = account_user) do
    ApiKey
    |> where([k], k.account_user_id == ^account_user.id)
    |> where([k], k.type in ^ApiKey.dashboard_types())
    |> order_by([k], desc: k.inserted_at, desc: k.id)
    |> Repo.all()
  end

  @doc "Gets one of the membership's API keys by ID, or `nil`."
  @spec get_api_key(AccountUser.t(), String.t()) :: ApiKey.t() | nil
  def get_api_key(%AccountUser{} = account_user, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        ApiKey
        |> where([k], k.id == ^uuid and k.account_user_id == ^account_user.id)
        |> where([k], k.type in ^ApiKey.dashboard_types())
        |> Repo.one()

      :error ->
        nil
    end
  end

  @doc "Revokes an API key. Revoked keys are kept for auditing, never deleted."
  @spec revoke_api_key(ApiKey.t()) :: {:ok, ApiKey.t()} | {:error, Ecto.Changeset.t()}
  def revoke_api_key(%ApiKey{} = api_key) do
    api_key
    |> Ecto.Changeset.change(status: :revoked)
    |> Repo.update()
  end
end
