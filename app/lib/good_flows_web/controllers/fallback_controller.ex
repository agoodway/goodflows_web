defmodule GoodFlowsWeb.FallbackController do
  @moduledoc """
  `action_fallback` for API controllers: turns `{:error, _}` results into
  JSON error responses.
  """
  use GoodFlowsWeb, :controller

  alias GoodFlowsWeb.{ChangesetJSON, ErrorJSON}
  alias Plug.Conn.Status

  @doc "Renders the error response for a controller action's `{:error, _}` result."
  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: ChangesetJSON)
    |> render(:error, changeset: changeset)
  end

  def call(conn, {:error, :active_run}) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: "The recipe has a queued or running run"}})
  end

  def call(conn, {:error, :has_recipes}) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: "The project still has recipes; delete them first"}})
  end

  def call(conn, {:error, :has_test_reports}) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: "The project has stored test reports and cannot be deleted"}})
  end

  def call(conn, {:error, :has_workflow_runs}) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: "The project has stored workflow runs and cannot be deleted"}})
  end

  def call(conn, {:error, {:invalid_test_report, errors}}) when is_map(errors) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: errors})
  end

  def call(conn, {:error, :test_report_conflict}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      errors: %{
        detail: "A different test report is already stored under this report identity"
      }
    })
  end

  def call(conn, {:error, :test_report_storage_unavailable}) do
    conn
    |> put_status(:service_unavailable)
    |> put_resp_header("retry-after", "1")
    |> json(%{errors: %{detail: "The test report could not be stored; retry the same request"}})
  end

  def call(conn, {:error, {:invalid_workflow_run, errors}}) when is_map(errors) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: errors})
  end

  def call(conn, {:error, :workflow_run_conflict}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      errors: %{
        detail: "A different workflow run is already stored under this run identity"
      }
    })
  end

  def call(conn, {:error, :workflow_run_storage_unavailable}) do
    conn
    |> put_status(:service_unavailable)
    |> put_resp_header("retry-after", "1")
    |> json(%{
      errors: %{detail: "The workflow run could not be stored; retry the same request"}
    })
  end

  def call(conn, {:error, {:conflict, active_run_id}}) when is_binary(active_run_id) do
    conn
    |> put_status(:conflict)
    |> json(%{
      errors: %{
        detail: "A run is already queued or running for this sprite",
        active_run_id: active_run_id
      }
    })
  end

  def call(conn, {:error, {:unprocessable, detail}}) when is_binary(detail) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{detail: detail}})
  end

  def call(conn, {:error, :admission_contended}) do
    conn
    |> put_status(:service_unavailable)
    |> put_resp_header("retry-after", "1")
    |> json(%{
      errors: %{
        detail: "Runs for this sprite were starting and finishing concurrently; retry the request"
      }
    })
  end

  def call(conn, {:error, {:enqueue_failed, _reason}}) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{errors: %{detail: "The run could not be queued; no run was created"}})
  end

  def call(conn, {:error, status}) when status in [:not_found, :forbidden, :unauthorized] do
    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", %{}))
  end
end
