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

  def call(conn, {:error, status}) when status in [:not_found, :forbidden, :unauthorized] do
    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", %{}))
  end
end
