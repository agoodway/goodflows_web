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

  def call(conn, {:error, :has_change_requests}) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: "The project has change requests and cannot be deleted"}})
  end

  def call(conn, {:error, :has_verify_runs}) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: "The project has verify runs and cannot be deleted"}})
  end

  def call(conn, {:error, :stale_digest}) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: "digest is not the current intent scenario set's digest"}})
  end

  def call(conn, {:error, :verify_run_conflict}) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: "A different verify run is already stored under this run id"}})
  end

  def call(conn, {:error, :artifact_too_large}) do
    conn
    |> put_status(413)
    |> json(%{errors: %{detail: "An artifact is larger than 50 MB"}})
  end

  def call(conn, {:error, :object_store_unconfigured}) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{errors: %{detail: "Artifacts need object storage, which is not configured"}})
  end

  def call(conn, {:error, {:invalid_body, errors}}) when is_map(errors) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: errors})
  end

  def call(conn, {:error, {:stale_head, head}}) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: "head is not the change request's current head", head: head}})
  end

  def call(conn, {:error, {:coded_conflict, error, extra}}) when is_map(extra) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: Map.merge(%{detail: conflict_detail(error), error: error}, extra)})
  end

  def call(conn, {:error, :invalid_transition}) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: "The change request's state does not allow this"}})
  end

  def call(conn, {:error, :not_active}) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: "Only draft and open change requests accept reports"}})
  end

  def call(conn, {:error, :merge_conflict}) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: "The change request was merged with another commit or branch"}})
  end

  def call(conn, {:error, :git_facts_conflict}) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: "Different Git facts are stored for this head and target"}})
  end

  def call(conn, {:error, :claims_conflict}) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: "Different claims are stored for this head"}})
  end

  def call(conn, {:error, :policy_version_conflict}) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: "previous_version is not the current policy version"}})
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

  def call(conn, {:error, :cache_conflict}) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: "The key is already committed or reserved in this scope"}})
  end

  def call(conn, {:error, :entry_too_large}) do
    conn
    |> put_status(413)
    |> json(%{errors: %{detail: "size is above the cache entry cap"}})
  end

  def call(conn, {:error, :quota_exceeded}) do
    conn
    |> put_status(507)
    |> json(%{
      errors: %{detail: "Unexpired reservations fill the project's cache quota; retry later"}
    })
  end

  def call(conn, {:error, :unsupported_media_type}) do
    conn
    |> put_status(:unsupported_media_type)
    |> json(ErrorJSON.render("415.json", %{}))
  end

  def call(conn, {:error, :object_store_unavailable}) do
    conn
    |> put_status(:service_unavailable)
    |> put_resp_header("retry-after", "1")
    |> json(%{errors: %{detail: "The cache object store is unavailable; retry the request"}})
  end

  def call(conn, {:error, status}) when status in [:not_found, :forbidden, :unauthorized] do
    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", %{}))
  end

  defp conflict_detail("not_open"), do: "The change request is not open"
  defp conflict_detail("stale_head"), do: "head is not the change request's current head"
  defp conflict_detail("not_mergeable"), do: "The change request's verdict is not mergeable"
  defp conflict_detail("slot_taken"), do: "Another lease holds the merge slot"
  defp conflict_detail("lease_not_active"), do: "The lease is unknown, released or expired"
  defp conflict_detail("not_editable"), do: "Only draft and open change requests can change"
  defp conflict_detail("parent_not_merged"), do: "The parent change request is not merged"
  defp conflict_detail("lease_held"), do: "The change request holds a merge lease"
end
