defmodule GoodFlowsWeb.Plugs.LoadProject do
  @moduledoc """
  Resolves the `:project` path segment to a project of the authenticated
  account and assigns it as `:project`.

  Must run last in its pipeline, after `GoodFlowsWeb.Plugs.ApiAuth` (and
  its `:require_write_access` check on write scopes), so `401` and `403`
  come before slug errors. An invalid slug halts with `422` and an error on
  `project` without querying; a valid slug with no project row halts with
  `404`. A missing project is never created here.
  """
  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller

  alias GoodFlows.Projects
  alias GoodFlows.Projects.Project
  alias GoodFlowsWeb.{ChangesetJSON, ErrorJSON}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    slug = conn.path_params["project"]

    if Project.valid_slug?(slug) do
      load(conn, slug)
    else
      conn
      |> put_status(:unprocessable_entity)
      |> json(ChangesetJSON.error(%{changeset: invalid_slug_changeset(slug)}))
      |> halt()
    end
  end

  defp load(conn, slug) do
    case Projects.get_project(conn.assigns.current_account, slug) do
      {:ok, project} ->
        assign(conn, :project, project)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(ErrorJSON.render("404.json", %{}))
        |> halt()
    end
  end

  defp invalid_slug_changeset(slug) do
    {%{}, %{project: :string}}
    |> Ecto.Changeset.change(%{project: slug})
    |> Ecto.Changeset.add_error(:project, "must be #{Project.slug_rule()}")
  end
end
