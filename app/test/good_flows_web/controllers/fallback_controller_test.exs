defmodule GoodFlowsWeb.FallbackControllerTest do
  use GoodFlowsWeb.ConnCase, async: true

  alias GoodFlowsWeb.FallbackController

  test "renders status errors as JSON", %{conn: conn} do
    conn = FallbackController.call(conn, {:error, :not_found})
    assert json_response(conn, 404) == %{"errors" => %{"detail" => "Not Found"}}
  end

  test "renders changeset errors with interpolated messages", %{conn: conn} do
    changeset =
      {%{}, %{name: :string}}
      |> Ecto.Changeset.cast(%{name: "x"}, [:name])
      |> Ecto.Changeset.validate_length(:name, min: 3)

    conn =
      conn
      |> Phoenix.Controller.put_format("json")
      |> FallbackController.call({:error, changeset})

    assert json_response(conn, 422) == %{
             "errors" => %{"name" => ["should be at least 3 character(s)"]}
           }
  end
end
