defmodule GoodFlows.Spry do
  @moduledoc """
  Hosted Spry: account-scoped recipes, the account's Sprites credential, and
  runs that drive a recipe phase against a Sprite VM.

  Every function takes the owning account and scopes its queries by
  `account_id`; records of other accounts are reported as `:not_found`.
  """
  import Ecto.Query

  require Logger

  alias GoodFlows.Accounts.Account
  alias GoodFlows.Repo
  alias GoodFlows.Spry.{Plan, Recipe, Run, RunJob, Sprites, SpritesCredential}

  @admission_attempts 5
  @dry_run_lookup_timeout_ms 15_000
  @no_credential "A Sprites credential must be configured for this account " <>
                   "(PUT /api/v1/sprites-credential) before starting a run"

  ## Recipes

  @doc "Lists the account's recipes ordered by name."
  @spec list_recipes(Account.t()) :: [Recipe.t()]
  def list_recipes(%Account{id: account_id}) do
    Recipe
    |> where(account_id: ^account_id)
    |> order_by([r], asc: r.name, asc: r.inserted_at)
    |> Repo.all()
  end

  @doc "Fetches one of the account's recipes."
  @spec get_recipe(Account.t(), term()) :: {:ok, Recipe.t()} | {:error, :not_found}
  def get_recipe(%Account{id: account_id}, id) do
    with {:ok, id} <- cast_id(id),
         %Recipe{} = recipe <- Repo.get_by(Recipe, id: id, account_id: account_id) do
      {:ok, recipe}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Creates a recipe for the account."
  @spec create_recipe(Account.t(), map()) :: {:ok, Recipe.t()} | {:error, Ecto.Changeset.t()}
  def create_recipe(%Account{id: account_id}, attrs) do
    %Recipe{account_id: account_id}
    |> Recipe.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Replaces a recipe wholesale; omitted phase lists become empty."
  @spec replace_recipe(Account.t(), term(), map()) ::
          {:ok, Recipe.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def replace_recipe(%Account{} = account, id, attrs) do
    with {:ok, recipe} <- get_recipe(account, id) do
      recipe
      |> Recipe.changeset(attrs)
      |> Repo.update()
    end
  end

  @doc """
  Deletes a recipe unless it has a queued or running run.

  Takes the same account-scoped `FOR UPDATE` lock on the recipe row as run
  admission, so a concurrent admission either commits first (deletion then
  returns `{:error, :active_run}`) or waits and then finds the recipe gone.
  Finished runs survive with `recipe_id` set to `nil`.
  """
  @spec delete_recipe(Account.t(), term()) :: :ok | {:error, :not_found | :active_run}
  def delete_recipe(%Account{} = account, id) do
    Repo.transact(fn ->
      with {:ok, recipe} <- lock_recipe(account, id),
           :ok <- ensure_no_active_run(recipe) do
        Repo.delete!(recipe)
        {:ok, :deleted}
      end
    end)
    |> case do
      {:ok, :deleted} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_recipe(%Account{id: account_id}, id) do
    with {:ok, id} <- cast_id(id),
         %Recipe{} = recipe <-
           Recipe
           |> where(id: ^id, account_id: ^account_id)
           |> lock("FOR UPDATE")
           |> Repo.one() do
      {:ok, recipe}
    else
      _ -> {:error, :not_found}
    end
  end

  defp ensure_no_active_run(%Recipe{id: recipe_id}) do
    active? =
      Run
      |> where([r], r.recipe_id == ^recipe_id and r.status in ^Run.active_statuses())
      |> Repo.exists?()

    if active?, do: {:error, :active_run}, else: :ok
  end

  ## Sprites credential

  @doc """
  Reports whether the account has a Sprites credential, its `last4`, and
  when it was last updated. Never includes the token.
  """
  @spec get_credential_status(Account.t()) :: %{
          configured: boolean(),
          last4: String.t() | nil,
          updated_at: DateTime.t() | nil
        }
  def get_credential_status(%Account{id: account_id}) do
    case Repo.get_by(SpritesCredential, account_id: account_id) do
      nil -> %{configured: false, last4: nil, updated_at: nil}
      cred -> %{configured: true, last4: cred.last4, updated_at: cred.updated_at}
    end
  end

  @doc """
  Sets or replaces the account's Sprites token. The insert is not logged:
  Ecto's debug query log prints parameters before the encrypted type dumps
  them, which would include the plaintext token.
  """
  @spec put_credential(Account.t(), map()) ::
          {:ok, SpritesCredential.t()} | {:error, Ecto.Changeset.t()}
  def put_credential(%Account{id: account_id}, attrs) do
    %SpritesCredential{account_id: account_id}
    |> SpritesCredential.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:token, :last4, :updated_at]},
      conflict_target: :account_id,
      returning: true,
      log: false
    )
  end

  @doc "Removes the account's Sprites credential. Succeeds when none exists."
  @spec delete_credential(Account.t()) :: :ok
  def delete_credential(%Account{id: account_id}) do
    SpritesCredential
    |> where(account_id: ^account_id)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Returns the account's decrypted Sprites token. Internal to run execution
  and dry runs: the token must never reach a response, log, or stored error.
  """
  @spec fetch_token(Ecto.UUID.t()) :: {:ok, String.t()} | {:error, :no_credential}
  def fetch_token(account_id) do
    case Repo.get_by(SpritesCredential, account_id: account_id) do
      %SpritesCredential{token: token} when is_binary(token) -> {:ok, token}
      _ -> {:error, :no_credential}
    end
  end

  ## Runs

  @default_page_size 50
  @max_page_size 200

  # The columns `GET /recipes/:id/runs` renders; the plan snapshot and
  # worker bookkeeping are never loaded for listings.
  @list_fields [
    :id,
    :account_id,
    :recipe_id,
    :status,
    :phase,
    :sprite_name,
    :inputs,
    :no_create,
    :no_destroy,
    :error,
    :started_by_api_key_id,
    :started_at,
    :finished_at,
    :inserted_at,
    :updated_at
  ]

  @typedoc "The result of a dry run."
  @type dry_run_result :: %{plan: Plan.t(), sprite_exists: boolean(), steps: [Plan.action()]}

  @typedoc "Errors from starting or dry-running a run."
  @type start_error ::
          :not_found
          | :admission_contended
          | Ecto.Changeset.t()
          | {:unprocessable, String.t()}
          | {:conflict, Ecto.UUID.t()}
          | {:enqueue_failed, term()}

  @doc """
  Handles `POST /recipes/:id/runs`, the single entry point for dry runs and
  real runs: validates the request with `Plan.build/2` (pure, so request
  errors win over a missing credential), then either dry-runs it or admits
  a real run.

  The choice comes only from the cast `dry_run` flag on the built plan, so
  every value Ecto's `:boolean` type accepts (`true`, `"true"`, `"1"`, …)
  means a dry run and no other code path re-interprets the raw parameter.

  A dry run checks the credential, looks up whether the sprite exists (the
  only Sprites call, bounded by a short 15-second timeout because it runs
  inside the HTTP request), and applies the VM rules, failing with the same
  error the run would report. It needs the stored credential to make that
  lookup, which is why it requires a private key like a real run.

  A real run checks the credential, then in one transaction locks the
  account-scoped recipe row, rebuilds the plan from it, inserts the queued
  run with its plan snapshot, and enqueues `GoodFlows.Spry.RunJob`. Any
  enqueue error rolls the transaction back (and is logged), so a run never
  exists without its job. Another active run for the same sprite gives
  `{:error, {:conflict, run_id}}`; if the conflicting run keeps finishing
  before it can be identified, admission is retried and finally returns
  `{:error, :admission_contended}` (a retryable `503`).

  Options: `:started_by_api_key_id`, recorded on an admitted run.
  """
  @spec request_run(Account.t(), term(), map(), keyword()) ::
          {:ok, {:plan, dry_run_result()} | {:run, Run.t()}}
          | {:error, start_error()}
  def request_run(%Account{} = account, recipe_id, params, opts \\ []) do
    with {:ok, recipe} <- get_recipe(account, recipe_id),
         {:ok, plan} <- Plan.build(recipe, params) do
      dispatch(account, recipe, plan, params, opts)
    end
  end

  defp dispatch(account, _recipe, %Plan{dry_run: true} = plan, _params, _opts),
    do: tag(plan_dry_run(account, plan), :plan)

  defp dispatch(account, recipe, _plan, params, opts),
    do: tag(admit_run(account, recipe, params, opts), :run)

  defp tag({:ok, value}, tag), do: {:ok, {tag, value}}
  defp tag({:error, _reason} = error, _tag), do: error

  defp plan_dry_run(account, plan) do
    with {:ok, token} <- require_token(account),
         {:ok, exists?} <- lookup_sprite(Sprites.client(token), plan.sprite_name),
         {:ok, steps} <- vm_steps(plan, exists?) do
      {:ok, %{plan: plan, sprite_exists: exists?, steps: steps}}
    end
  end

  defp require_token(%Account{id: account_id}) do
    case fetch_token(account_id) do
      {:ok, token} -> {:ok, token}
      {:error, :no_credential} -> {:error, {:unprocessable, @no_credential}}
    end
  end

  defp lookup_sprite(client, name) do
    case Sprites.exists?(client, name, timeout: @dry_run_lookup_timeout_ms) do
      {:ok, exists?} ->
        {:ok, exists?}

      {:error, :timeout} ->
        {:error, {:unprocessable, "timed out checking whether sprite #{name} exists"}}

      {:error, error} ->
        {:error,
         {:unprocessable,
          "could not check whether sprite #{name} exists: #{Sprites.error_message(error)}"}}
    end
  end

  defp vm_steps(plan, exists?) do
    case Plan.with_vm_state(plan, exists?) do
      {:ok, steps} -> {:ok, steps}
      {:error, message} -> {:error, {:unprocessable, message}}
    end
  end

  defp admit_run(account, recipe, params, opts) do
    with {:ok, _token} <- require_token(account) do
      admit(account, recipe.id, params, opts, @admission_attempts)
    end
  end

  defp admit(account, recipe_id, params, opts, attempts_left) do
    case Repo.transaction(fn -> insert_and_enqueue(account, recipe_id, params, opts) end) do
      {:ok, run} ->
        {:ok, run}

      {:error, {:active_conflict, sprite_name}} ->
        resolve_conflict(account, recipe_id, params, opts, sprite_name, attempts_left)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_and_enqueue(account, recipe_id, params, opts) do
    with {:ok, recipe} <- lock_recipe(account, recipe_id),
         {:ok, plan} <- Plan.build(recipe, params),
         {:ok, run} <- insert_run(account, recipe, plan, opts),
         {:ok, pgflow_run_id} <- enqueue(run) do
      run
      |> Ecto.Changeset.change(pgflow_run_id: pgflow_run_id)
      |> Repo.update!()
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert_run(account, recipe, plan, opts) do
    attrs = %{
      phase: plan.phase,
      sprite_name: plan.sprite_name,
      inputs: plan.inputs,
      no_create: plan.no_create,
      no_destroy: plan.no_destroy,
      plan: Plan.snapshot(plan),
      started_by_api_key_id: Keyword.get(opts, :started_by_api_key_id)
    }

    case Repo.insert(
           Run.admission_changeset(%Run{account_id: account.id, recipe_id: recipe.id}, attrs)
         ) do
      {:ok, run} ->
        {:ok, run}

      {:error, changeset} ->
        if active_run_conflict?(changeset),
          do: {:error, {:active_conflict, plan.sprite_name}},
          else: {:error, changeset}
    end
  end

  # Only the one-active-run partial unique index is a conflict; any other
  # error (including other constraints on `sprite_name`) stays a changeset.
  defp active_run_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:sprite_name, {_message, opts}} ->
        opts[:constraint] == :unique and
          opts[:constraint_name] == "runs_one_active_per_sprite_index"

      _other ->
        false
    end)
  end

  defp enqueue(run) do
    case PgFlow.enqueue(RunJob, %{"run_id" => run.id}) do
      {:ok, pgflow_run_id} ->
        {:ok, pgflow_run_id}

      {:error, reason} ->
        Logger.error(
          "Could not enqueue Spry run #{run.id} (rolled back, no run created): #{inspect(reason)}"
        )

        {:error, {:enqueue_failed, reason}}
    end
  end

  # Runs after the failed transaction has rolled back, so the lookup never
  # happens inside an aborted transaction.
  defp resolve_conflict(account, recipe_id, params, opts, sprite_name, attempts_left) do
    case __MODULE__.active_run_id(account, sprite_name) do
      nil when attempts_left > 1 -> admit(account, recipe_id, params, opts, attempts_left - 1)
      nil -> {:error, :admission_contended}
      active_id -> {:error, {:conflict, active_id}}
    end
  end

  @doc "The id of the account's queued or running run for `sprite_name`, if any."
  @spec active_run_id(Account.t(), String.t()) :: Ecto.UUID.t() | nil
  def active_run_id(%Account{id: account_id}, sprite_name) do
    Run
    |> where([r], r.account_id == ^account_id and r.sprite_name == ^sprite_name)
    |> where([r], r.status in ^Run.active_statuses())
    |> select([r], r.id)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Fetches one of the account's runs with its steps in order."
  @spec get_run(Account.t(), term()) :: {:ok, Run.t()} | {:error, :not_found}
  def get_run(%Account{id: account_id}, id) do
    with {:ok, id} <- cast_id(id),
         %Run{} = run <- Repo.get_by(Run, id: id, account_id: account_id) do
      {:ok, Repo.preload(run, :steps)}
    else
      _ -> {:error, :not_found}
    end
  end

  @typedoc "One page of a recipe's runs; `next_cursor` is `nil` on the last page."
  @type run_page :: %{runs: [Run.t()], next_cursor: String.t() | nil}

  @doc """
  Lists one page of a recipe's runs, newest first, without steps and
  loading only the rendered columns.

  Params (string keys, as from a query string): `"limit"` (1 to
  #{@max_page_size}, default #{@default_page_size}) and `"cursor"` (the
  `next_cursor` of the previous page). Pages use keyset pagination on
  `(inserted_at, id)`, so runs started meanwhile never shift a page.
  Invalid params return a changeset (`422`).
  """
  @spec list_runs(Account.t(), term(), map()) ::
          {:ok, run_page()} | {:error, :not_found | Ecto.Changeset.t()}
  def list_runs(%Account{} = account, recipe_id, params \\ %{}) do
    with {:ok, recipe} <- get_recipe(account, recipe_id),
         {:ok, %{limit: limit, cursor: cursor}} <- page_params(params) do
      runs =
        Run
        |> where(recipe_id: ^recipe.id, account_id: ^account.id)
        |> after_cursor(cursor)
        |> order_by([r], desc: r.inserted_at, desc: r.id)
        |> limit(^(limit + 1))
        |> select([r], struct(r, ^@list_fields))
        |> Repo.all()

      {page, rest} = Enum.split(runs, limit)
      next_cursor = if rest != [], do: encode_cursor(List.last(page))
      {:ok, %{runs: page, next_cursor: next_cursor}}
    end
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {inserted_at, id}) do
    where(
      query,
      [r],
      r.inserted_at < ^inserted_at or (r.inserted_at == ^inserted_at and r.id < ^id)
    )
  end

  defp page_params(params) do
    types = %{limit: :integer, cursor: :string}

    {%{limit: @default_page_size, cursor: nil}, types}
    |> Ecto.Changeset.cast(params, Map.keys(types))
    |> Ecto.Changeset.validate_number(:limit,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @max_page_size
    )
    |> validate_cursor()
    |> Ecto.Changeset.apply_action(:list)
  end

  defp validate_cursor(changeset) do
    case Ecto.Changeset.get_change(changeset, :cursor) do
      nil ->
        changeset

      cursor ->
        case decode_cursor(cursor) do
          {:ok, decoded} -> Ecto.Changeset.put_change(changeset, :cursor, decoded)
          :error -> Ecto.Changeset.add_error(changeset, :cursor, "is invalid")
        end
    end
  end

  defp encode_cursor(%Run{inserted_at: inserted_at, id: id}) do
    Base.url_encode64("#{DateTime.to_iso8601(inserted_at)}|#{id}", padding: false)
  end

  defp decode_cursor(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [timestamp, id] <- String.split(decoded, "|", parts: 2),
         {:ok, inserted_at, 0} <- DateTime.from_iso8601(timestamp),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {inserted_at, id}}
    else
      _ -> :error
    end
  end

  @doc """
  Operator-only: releases a `running` run whose owner cannot be
  investigated (see `GoodFlows.Spry.Reaper.force_abandon/1`). Not
  account-scoped and not exposed over the API.
  """
  @spec force_abandon(Ecto.UUID.t()) :: {:ok, Run.t()} | {:error, :not_found | :not_running}
  defdelegate force_abandon(run_id), to: GoodFlows.Spry.Reaper

  defp cast_id(id), do: Ecto.UUID.cast(id)
end
