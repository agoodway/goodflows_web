defmodule GoodFlows.Repo.Migrations.AddChangeRequestIterationHistory do
  @moduledoc """
  Keeps the history behind a change request's fix iterations.

  `change_request_verdict_transitions` holds one row per recompute that
  changed a verdict's state, head or policy version, with its `cause` and,
  for a head change, the new head's `head_kind`. `change_request_reason_spans`
  holds one row per time a reason (`rule`, `subject`, `outcome`) is in the
  verdict, from the recompute that opened it to the one, merge or close
  that closed it. Both are written once (a span is closed once) and
  deleted only with their change request; the project event sweep does
  not touch them.

  `change_request_git_facts` gains `previous_head` and `head_kind`, and
  `change_requests` gains `merged_fix_iterations` and `merged_head_count`.
  All four are null for rows written before this migration; nothing is
  backfilled.
  """
  use Ecto.Migration

  def change do
    create table(:change_request_verdict_transitions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :change_request_id,
          references(:change_requests, type: :binary_id, on_delete: :delete_all),
          null: false

      add :from_state, :text
      add :to_state, :text, null: false
      add :from_head, :text
      add :to_head, :text
      add :policy_version, :integer, null: false
      add :cause, :text, null: false
      add :head_kind, :text
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create constraint(:change_request_verdict_transitions, :cause_check,
             check: "cause IN ('created', 'head', 'policy', 'inputs')"
           )

    create index(:change_request_verdict_transitions, [:change_request_id, :inserted_at])

    create table(:change_request_reason_spans, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :change_request_id,
          references(:change_requests, type: :binary_id, on_delete: :delete_all),
          null: false

      add :rule, :text, null: false
      add :subject, {:array, :text}, null: false
      add :outcome, :text, null: false
      add :opened_head, :text
      add :opened_policy_version, :integer, null: false
      add :opened_at, :utc_datetime_usec, null: false
      add :inherited, :boolean, null: false, default: false
      add :closed_head, :text
      add :closed_at, :utc_datetime_usec
      add :close_cause, :text
      add :close_head_kind, :text
    end

    create constraint(:change_request_reason_spans, :close_cause_check,
             check:
               "close_cause IS NULL OR close_cause IN ('head', 'policy', 'inputs', 'merged', 'closed')"
           )

    create index(:change_request_reason_spans, [:change_request_id, :opened_at])

    create index(:change_request_reason_spans, [:change_request_id],
             where: "closed_at IS NULL",
             name: :change_request_reason_spans_open_index
           )

    alter table(:change_request_git_facts) do
      add :previous_head, :text
      add :head_kind, :text
    end

    alter table(:change_requests) do
      add :merged_fix_iterations, :integer
      add :merged_head_count, :integer
    end
  end
end
