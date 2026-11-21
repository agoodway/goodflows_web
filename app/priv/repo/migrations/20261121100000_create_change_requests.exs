defmodule GoodFlows.Repo.Migrations.CreateChangeRequests do
  @moduledoc """
  Creates `change_requests` and the per-project number counter
  `projects.change_request_seq`.

  `project_id` is a composite foreign key `(project_id, account_id)` to
  `projects (id, account_id)` with `ON DELETE NO ACTION`, like
  `workflow_runs`: a project with change requests cannot be deleted, while
  an account delete cascades to both.

  `number` is unique per project. It is taken from
  `projects.change_request_seq`, which `GoodFlows.ChangeRequests.create/3`
  increments with `UPDATE … RETURNING` (a row lock), so concurrent creates
  get distinct numbers and a number is never reused.

  `link_tickets` (ASCII-lowercased) and `link_threads` copy `links` like
  the `workflow_runs` columns, with GIN indexes. The `merged_*` columns
  hold the merge report and the verdict at the merged head; they are
  written once.
  """
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :change_request_seq, :bigint, null: false, default: 0
    end

    create table(:change_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id,
          references(:projects,
            column: :id,
            with: [account_id: :account_id],
            name: :change_requests_project_id_fkey,
            type: :binary_id,
            on_delete: :nothing
          ),
          null: false

      add :number, :bigint, null: false
      add :title, :text, null: false
      add :source_branch, :text, null: false
      add :target_branch, :text, null: false
      add :openspec_change, :text
      add :links, :map
      add :link_tickets, {:array, :text}, null: false, default: fragment("'{}'")
      add :link_threads, {:array, :text}, null: false, default: fragment("'{}'")
      add :state, :text, null: false
      add :closed_from_state, :text
      add :head, :text

      add :opened_by_account_user_id,
          references(:account_users, type: :binary_id, on_delete: :nilify_all)

      add :opened_by_api_key_id, references(:api_keys, type: :binary_id, on_delete: :nilify_all)

      add :merged_commit, :text
      add :merged_target_branch, :text
      add :merged_at, :utc_datetime_usec
      add :merged_head, :text
      add :merged_verdict_state, :text
      add :merged_policy_version, :bigint
      add :merged_reasons, :map
      add :merged_without_mergeable_verdict, :boolean

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:change_requests, [:project_id, :number],
             name: :change_requests_project_id_number_index
           )

    create index(:change_requests, [:project_id, :state], name: :change_requests_state_index)

    create index(:change_requests, [:project_id, :source_branch],
             name: :change_requests_source_branch_index
           )

    create index(:change_requests, [:project_id, :head], name: :change_requests_head_index)
    create index(:change_requests, [:account_id])

    create index(:change_requests, [:link_tickets],
             using: :gin,
             name: :change_requests_link_tickets_index
           )

    create index(:change_requests, [:link_threads],
             using: :gin,
             name: :change_requests_link_threads_index
           )

    create index(:change_requests, [:opened_by_account_user_id])
    create index(:change_requests, [:opened_by_api_key_id])
  end
end
