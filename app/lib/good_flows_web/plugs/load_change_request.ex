defmodule GoodFlowsWeb.Plugs.LoadChangeRequest do
  @moduledoc """
  Resolves the `:number` path segment to a change request of the loaded
  project (`GoodFlowsWeb.Plugs.LoadProject`) and assigns it as
  `:change_request`, before any body is read. A segment that is not a
  positive integer is `422` on `number`; a number with no change request
  in the project is `404`.
  """
  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller

  alias GoodFlows.ChangeRequests
  alias GoodFlowsWeb.ErrorJSON

  @number ~r/\A[1-9][0-9]{0,15}\z/

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {:ok, number} <- parse(conn.path_params["number"]),
         {:ok, change_request} <- ChangeRequests.get(conn.assigns.project, number) do
      assign(conn, :change_request, change_request)
    else
      :invalid ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{"number" => ["must be a positive integer"]}})
        |> halt()

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(ErrorJSON.render("404.json", %{})) |> halt()
    end
  end

  @doc "Parses a positive decimal integer path segment."
  @spec parse(term()) :: {:ok, pos_integer()} | :invalid
  def parse(value) when is_binary(value) do
    if Regex.match?(@number, value), do: {:ok, String.to_integer(value)}, else: :invalid
  end

  def parse(_value), do: :invalid
end
