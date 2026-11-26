defmodule GoodFlowsWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import GoodFlowsWeb.CoreComponents

  alias Phoenix.LiveView.LiveStream

  describe "table/1 details" do
    defp render_table(assigns) do
      ~H"""
      <.table
        id="things"
        rows={@rows}
        row_id={&"thing-#{&1.id}"}
        row_open={&(&1.id in @open)}
      >
        <:col :let={row} label="ID">{row.id}</:col>
        <:col :let={row} label="Name">{row.name}</:col>
        <:col label="Size">1</:col>
        <:action :if={@action?}>Edit</:action>
        <:details :let={row}>
          <p class="detail-text">Details of {row.name}</p>
        </:details>
      </.table>
      """
      |> rendered_to_string()
      |> LazyHTML.from_fragment()
    end

    @rows [%{id: 1, name: "One"}, %{id: 2, name: "Two"}, %{id: 3, name: "Three"}]

    test "only open rows get a details row, directly below them, spanning every column" do
      doc = render_table(%{rows: @rows, open: [2], action?: false})

      ids = doc |> LazyHTML.query("#things > tr") |> LazyHTML.attribute("id")
      assert ids == ["thing-1", "thing-2", "thing-2-details", "thing-3"]

      cell = LazyHTML.query(doc, "#thing-2-details > td")
      assert LazyHTML.attribute(cell, "colspan") == ["3"]
      assert LazyHTML.attribute(cell, "data-label") == [""]
      assert cell |> LazyHTML.query(".detail-text") |> LazyHTML.text() == "Details of Two"
    end

    test "the details cell also spans the actions column" do
      doc = render_table(%{rows: @rows, open: [1, 3], action?: true})

      for id <- ["thing-1-details", "thing-3-details"] do
        assert doc |> LazyHTML.query("##{id} > td") |> LazyHTML.attribute("colspan") == ["4"]
      end

      assert doc |> LazyHTML.query("#thing-2-details") |> Enum.empty?()
    end

    test "without row_open no details row renders" do
      assigns = %{rows: @rows}

      doc =
        ~H"""
        <.table id="things" rows={@rows} row_id={&"thing-#{&1.id}"}>
          <:col :let={row} label="ID">{row.id}</:col>
          <:details>never</:details>
        </.table>
        """
        |> rendered_to_string()
        |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query(".data-table-details") |> Enum.empty?()
    end

    test "row_open with a stream raises" do
      assigns = %{rows: LiveStream.new(:things, "0", @rows, [])}

      assert_raise ArgumentError, ~r/list rows only/, fn ->
        ~H"""
        <.table id="things" rows={@rows} row_open={fn _ -> true end}>
          <:col :let={{_id, row}} label="ID">{row.id}</:col>
          <:details>never</:details>
        </.table>
        """
        |> rendered_to_string()
      end
    end
  end
end
