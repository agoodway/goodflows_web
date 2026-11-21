defmodule GoodFlows.Repo.Migrations.CreateReviewTasks do
  @moduledoc """
  Creates `review_tasks`: the work a `request_change` or `reject` answer
  asks of the author agent, with the item, note and head of the answer,
  a `state` of `open`, `stale` or `done`, and who created and completed
  it. Tasks go with their change request.
  """
  use Ecto.Migration

  def change do
    create table(:review_tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :change_request_id,
          references(:change_requests, type: :binary_id, on_delete: :delete_all),
          null: false

      add :answer_id, references(:review_answers, type: :binary_id, on_delete: :delete_all),
        null: false

      add :item_id, :text, null: false
      add :kind, :text, null: false
      add :answer, :text, null: false
      add :note, :text, null: false
      add :head, :text
      add :state, :text, null: false

      add :created_by_account_user_id,
          references(:account_users, type: :binary_id, on_delete: :nilify_all)

      add :done_by_account_user_id,
          references(:account_users, type: :binary_id, on_delete: :nilify_all)

      add :done_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:review_tasks, [:change_request_id, :state, :inserted_at])
    create index(:review_tasks, [:answer_id])
    create index(:review_tasks, [:created_by_account_user_id])
    create index(:review_tasks, [:done_by_account_user_id])
  end
end
