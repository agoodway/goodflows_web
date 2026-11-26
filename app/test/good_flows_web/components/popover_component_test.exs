defmodule GoodFlowsWeb.PopoverComponentTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import GoodFlowsWeb.CoreComponents

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp attribute(html, selector, name), do: html |> query(selector) |> LazyHTML.attribute(name)

  test "the trigger opens the panel, an auto popover placed by the hook" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.popover id="key-note">
        <:trigger>Add note</:trigger>
        Shown to everyone who can see this key.
      </.popover>
      """)

    assert attribute(html, "button#key-note-trigger", "popovertarget") == ["key-note"]
    assert attribute(html, "button#key-note-trigger", "type") == ["button"]
    assert attribute(html, "button#key-note-trigger", "aria-haspopup") == ["dialog"]

    assert html |> query("button#key-note-trigger.ui-button.ui-button-outline") |> Enum.count() ==
             1

    assert attribute(html, "#key-note", "popover") == ["auto"]
    assert attribute(html, "#key-note", "role") == ["dialog"]
    assert attribute(html, "#key-note", "phx-hook") == ["GoodFlowsWeb.CoreComponents.Popover"]
    assert attribute(html, "#key-note", "data-trigger") == ["key-note-trigger"]
    assert attribute(html, "#key-note", "data-side") == ["bottom"]
    assert attribute(html, "#key-note", "data-align") == ["center"]
    assert html |> query("#key-note.popover-panel.w-72") |> Enum.count() == 1
    assert html |> query("#key-note") |> LazyHTML.text() =~ "everyone who can see"
    assert attribute(html, "#key-note > #key-note-arrow", "aria-hidden") == ["true"]
  end

  test "the title and description name and describe the panel" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.popover id="note" side="right" align="start" arrow={false}>
        <:trigger>Add note</:trigger>
        <:title>Key note</:title>
        <:description>Shown to everyone who can see this key.</:description>
      </.popover>
      """)

    assert attribute(html, "#note", "aria-labelledby") == ["note-title"]
    assert attribute(html, "#note", "aria-describedby") == ["note-description"]
    assert html |> query("#note-title") |> LazyHTML.text() =~ "Key note"
    assert attribute(html, "#note", "data-side") == ["right"]
    assert attribute(html, "#note", "data-align") == ["start"]
    assert html |> query("#note-arrow") |> Enum.count() == 0
  end

  test "without a title the panel has no labelledby, and the trigger takes button options" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.popover id="help">
        <:trigger variant="ghost" size="sm" aria-label="About required workflows">?</:trigger>
        A required workflow must pass before a change request can merge.
      </.popover>
      """)

    assert html |> query("#help[aria-labelledby]") |> Enum.count() == 0
    assert attribute(html, "#help-trigger", "aria-label") == ["About required workflows"]
    assert html |> query("#help-trigger.ui-button-ghost.ui-button-sm") |> Enum.count() == 1
  end

  test "a refused trigger stays focusable, is described by the reason and opens nothing" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.popover id="rerun">
        <:trigger refused="Only owners can rerun checks." describedby="rerun-hint">
          Rerun
        </:trigger>
        Choose what to rerun.
      </.popover>
      """)

    assert attribute(html, "#rerun-trigger", "popovertarget") == []
    assert attribute(html, "#rerun-trigger", "disabled") == []
    assert attribute(html, "#rerun-trigger", "aria-disabled") == ["true"]
    assert attribute(html, "#rerun-trigger", "aria-describedby") == ["rerun-refused rerun-hint"]
    assert html |> query("#rerun-refused.sr-only") |> LazyHTML.text() =~ "Only owners"
  end

  test "the JS helpers dispatch to the panel" do
    for {fun, action} <- [show_popover: "show", hide_popover: "hide", toggle_popover: "toggle"] do
      assert %Phoenix.LiveView.JS{ops: [["dispatch", opts]]} =
               apply(GoodFlowsWeb.CoreComponents, fun, ["note"])

      assert opts.to == "#note"
      assert opts.event == "gf:popover"
      assert opts.detail == %{action: action}
    end
  end

  test "open and close events are opt-in and reported to a target" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.popover id="plain-note">
        <:trigger>Add note</:trigger>
        Shown to everyone who can see this key.
      </.popover>
      <.popover id="followed" on_open="opened" on_close="closed" target="#owner">
        <:trigger>Open</:trigger>
        Followed by the server.
      </.popover>
      """)

    assert attribute(html, "#plain-note", "data-on-open") == []
    assert attribute(html, "#plain-note", "data-on-close") == []
    assert attribute(html, "#followed", "data-on-open") == ["opened"]
    assert attribute(html, "#followed", "data-on-close") == ["closed"]
    assert attribute(html, "#followed", "data-event-target") == ["#owner"]
    assert attribute(html, "#plain-note", "data-show-on-mount") == []
    assert attribute(html, "#plain-note", "data-restore-focus") == []
  end

  test "a panel shared by another control has no trigger of its own" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.popover id="complete" for="task-complete" show_on_mount restore_focus>
        <:title>Complete?</:title>
        Choose an outcome.
      </.popover>
      """)

    assert attribute(html, "#complete", "data-trigger") == ["task-complete"]
    assert attribute(html, "#complete", "data-show-on-mount") == ["true"]
    assert attribute(html, "#complete", "data-restore-focus") == ["true"]
    assert html |> query("button#complete-trigger") |> Enum.count() == 0
  end
end
