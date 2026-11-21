defmodule GoodFlows.Repo.Migrations.AddLinksToWorkflowRuns do
  @moduledoc """
  Copies `links` out of `payload` so the `ticket` and `thread_url` list
  filters never read `payload`: `link_tickets` (each ticket
  ASCII-lowercased) and `link_threads` (each thread URL as sent). Both are
  `text[] NOT NULL DEFAULT '{}'`. A constant default is a catalog-only
  change, so existing rows are not rewritten. Rows stored before this
  migration could not carry `links`, so they read back as empty arrays and
  need no backfill.

  Each column gets a GIN index for `@>` lookups. A GIN index cannot carry
  the keyset order, so a link filter rechecks the project and sorts the
  few runs that name one ticket or thread.

  The rollback is for development only. In production the columns stay
  when the code is rolled back: dropping them would lose the copies of
  runs stored with `links`, and re-adding them would need a backfill from
  `payload`.
  """
  use Ecto.Migration

  def change do
    alter table(:workflow_runs) do
      add :link_tickets, {:array, :text}, null: false, default: fragment("'{}'")
      add :link_threads, {:array, :text}, null: false, default: fragment("'{}'")
    end

    create index(:workflow_runs, [:link_tickets],
             using: :gin,
             name: :workflow_runs_link_tickets_index
           )

    create index(:workflow_runs, [:link_threads],
             using: :gin,
             name: :workflow_runs_link_threads_index
           )
  end
end
