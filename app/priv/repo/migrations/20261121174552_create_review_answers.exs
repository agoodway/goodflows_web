defmodule GoodFlows.Repo.Migrations.CreateReviewAnswers do
  @moduledoc """
  Creates `review_answers`: answers to review packet items, each bound to
  the head it was given at (null before any `git-facts` report). A later
  answer to the same item at the same head sets `superseded_at` on the
  earlier one; at most one answer per change request, item and head is
  current, with two null heads counting as equal (`NULLS NOT DISTINCT`).
  Answers go with their change request.
  """
  use Ecto.Migration

  def up do
    create table(:review_answers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :change_request_id,
          references(:change_requests, type: :binary_id, on_delete: :delete_all),
          null: false

      add :item_id, :text, null: false
      add :kind, :text, null: false
      add :rule, :text, null: false
      add :head, :text
      add :answer, :text, null: false
      add :option, :text
      add :note, :text
      add :account_user_id, references(:account_users, type: :binary_id, on_delete: :nilify_all)
      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :nilify_all)
      add :channel, :text, null: false
      add :superseded_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    execute """
    CREATE UNIQUE INDEX review_answers_current_index
    ON review_answers (change_request_id, item_id, head) NULLS NOT DISTINCT
    WHERE superseded_at IS NULL
    """

    create index(:review_answers, [:change_request_id, :head])
    create index(:review_answers, [:account_user_id])
    create index(:review_answers, [:api_key_id])
  end

  def down do
    drop table(:review_answers)
  end
end
