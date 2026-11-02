defmodule GoodFlowsWeb.Plugs.RequireParsedBody do
  @moduledoc """
  Halts `POST`, `PUT` and `PATCH` requests whose body the endpoint parser
  left unparsed with `415`.

  The endpoint's `Plug.Parsers` passes unknown content types (`pass:
  ["*/*"]`), leaving `body_params` as `Plug.Conn.Unfetched`. Controllers
  expect a map, so a `text/plain` body would otherwise crash with `500`.
  Requests without a `Content-Type` are parsed to `%{}` and pass through.

  Runs after `GoodFlowsWeb.Plugs.ApiAuth` on write scopes, so `401` and
  `403` come first. Raw-body routes (`GoodFlowsWeb.Plugs.BodyParsers.raw_body_route?/1`:
  test report and pool workspace uploads) are skipped: their body is
  deliberately unparsed and read by their own controllers.
  """
  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller

  alias GoodFlowsWeb.ErrorJSON
  alias GoodFlowsWeb.Plugs.BodyParsers

  @body_methods ~w(POST PUT PATCH)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: method, body_params: %Plug.Conn.Unfetched{}} = conn, _opts)
      when method in @body_methods do
    if BodyParsers.raw_body_route?(conn) do
      conn
    else
      conn
      |> put_status(:unsupported_media_type)
      |> json(ErrorJSON.render("415.json", %{}))
      |> halt()
    end
  end

  def call(conn, _opts), do: conn
end
