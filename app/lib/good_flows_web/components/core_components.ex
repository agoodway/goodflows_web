defmodule GoodFlowsWeb.CoreComponents do
  @moduledoc """
  The app-wide UI primitives. Every page builds its controls from these
  instead of writing its own markup, which is what keeps the interface
  consistent.

  Before writing markup, look here and in `lib/good_flows_web/components/`.
  If a control or layout would appear in a second place, add it here and use
  it in both. `DESIGN.md` at the repository root is the catalog of these
  components and the visual rules they follow; their classes (`ui-button`,
  `ui-input`, `status-badge`, ...) are defined in `assets/css/app.css`.

  This module is imported once, in `GoodFlowsWeb.html_helpers/0`.
  """
  use Phoenix.Component
  use Gettext, backend: GoodFlowsWeb.Gettext

  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={["flash", "flash-#{@kind}"]}
      {@rest}
    >
      <.icon :if={@kind == :info} name="hero-information-circle" class="flash-icon size-4" />
      <.icon :if={@kind == :error} name="hero-exclamation-circle" class="flash-icon size-4" />
      <div class="min-w-0 flex-1">
        <p :if={@title} class="font-semibold">{@title}</p>
        <p class="break-words">{msg}</p>
      </div>
      <button type="button" class="text-muted hover:text-base-content" aria-label={gettext("close")}>
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </div>
    """
  end

  @doc """
  Renders a button, or a link styled as one when given `href`, `navigate`
  or `patch`.

  Variants:

    * `primary` - the page's or dialog's one main action
    * `soft` - the default, for secondary actions
    * `ghost` - quiet row and header actions
    * `outline` - quiet bordered actions such as pagers and retries
    * `danger` - the confirm button of a destructive dialog

  Use `size="sm"` in rows, toolbars and headers. `class` is added to the
  variant's classes; pass it for layout (width, margin) only.

  ## Examples

      <.button>Send</.button>
      <.button phx-click="go" variant="primary">Send</.button>
      <.button navigate={~p"/"} variant="ghost" size="sm">Home</.button>
  """
  attr :rest, :global,
    include: ~w(href navigate patch method download name value disabled type popovertarget)

  attr :class, :any, default: nil
  attr :variant, :string, default: "soft", values: ~w(primary soft ghost outline danger)
  attr :size, :string, default: "md", values: ~w(sm md)
  attr :icon, :string, default: nil
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns =
      assign(assigns, :classes, [
        "ui-button",
        "ui-button-#{assigns.variant}",
        "ui-button-#{assigns.size}",
        assigns.class
      ])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@classes} {@rest}>
        <.icon :if={@icon} name={@icon} class="size-4 shrink-0" />
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@classes} {@rest}>
        <.icon :if={@icon} name={@icon} class="size-4 shrink-0" />
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders a link inside running text.

  ## Examples

      <.text_link navigate={~p"/users/register"}>Sign up</.text_link>
  """
  attr :rest, :global, include: ~w(href navigate patch method download)
  slot :inner_block, required: true

  def text_link(assigns) do
    ~H"""
    <.link class="ui-link" {@rest}>{render_slot(@inner_block)}</.link>
    """
  end

  @doc """
  Renders a status or tag. Write the status in words, in sentence case: the
  colour only supports it.

  Kinds: `neutral` (the default), `primary` (positive or current), `error`.

  ## Examples

      <.status_badge kind="primary" dot>Active</.status_badge>
  """
  attr :kind, :string, default: "neutral", values: ~w(neutral primary error)
  attr :dot, :boolean, default: false
  slot :inner_block, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={["status-badge", "status-badge-#{@kind}"]}>
      <span :if={@dot} aria-hidden="true" class="size-1.5 rounded-full bg-current"></span>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  Renders a short literal value, such as a key prefix or a step number, as
  code. Unlike `status_badge/1` it keeps the value's own casing.

  ## Examples

      <.tag>pk_live_ab12…</.tag>
  """
  slot :inner_block, required: true

  def tag(assigns) do
    ~H"""
    <code class="tag-badge">{render_slot(@inner_block)}</code>
    """
  end

  @doc """
  Renders an inline notice that stays on the page, unlike a flash.

  ## Examples

      <.notice kind="warning">Copy the key now. It is not shown again.</.notice>
  """
  attr :kind, :string, default: "neutral", values: ~w(neutral info warning)
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def notice(assigns) do
    ~H"""
    <div class={["ui-notice", "ui-notice-#{@kind}", @class]}>
      <.icon
        :if={@kind == "info"}
        name="hero-information-circle-mini"
        class="ui-notice-icon size-4"
      />
      <.icon
        :if={@kind == "warning"}
        name="hero-exclamation-triangle-mini"
        class="ui-notice-icon size-4"
      />
      <div class="min-w-0 flex-1">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  An invalid field shows an icon and the message under it. Each message
  has an id that the field names in `aria-describedby`.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  Unsupported types, such as radio, are best written directly in your
  templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" label="Email" />
  <.input field={@form[:type]} type="select" label="Type" options={["Admin": "admin"]} />
  ```

  For what `options` accepts, see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"
  attr :hint, :string, default: nil, doc: "help text shown below a text-like input"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="ui-field">
      <input
        type="hidden"
        name={@name}
        value="false"
        disabled={@rest[:disabled]}
        form={@rest[:form]}
      />
      <label for={@id} class="flex items-center gap-2 text-sm">
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={@class || "ui-checkbox"}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={error_ids(@id || @name, @errors)}
          {@rest}
        />{@label}
      </label>
      <.field_errors base={@id || @name} errors={@errors} />
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="ui-field">
      <label :if={@label} for={@id} class="ui-field-label">{@label}</label>
      <div class="relative">
        <select
          id={@id}
          name={@name}
          class={[
            @class || "ui-input ui-select",
            @errors != [] && (@error_class || "ui-input-error")
          ]}
          multiple={@multiple}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={error_ids(@id || @name, @errors)}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Form.options_for_select(@options, @value)}
        </select>
        <.icon :if={!@multiple} name="hero-chevron-down-micro" class="ui-select-icon size-4" />
      </div>
      <.field_errors base={@id || @name} errors={@errors} />
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="ui-field">
      <label :if={@label} for={@id} class="ui-field-label">{@label}</label>
      <textarea
        id={@id}
        name={@name}
        class={[
          @class || "ui-input ui-textarea",
          @errors != [] && (@error_class || "ui-input-error")
        ]}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={error_ids(@id || @name, @errors)}
        {@rest}
      >{Form.normalize_value("textarea", @value)}</textarea>
      <.field_errors base={@id || @name} errors={@errors} />
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="ui-field">
      <label :if={@label} for={@id} class="ui-field-label">{@label}</label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Form.normalize_value(@type, @value)}
        class={[
          @class || "ui-input",
          @errors != [] && (@error_class || "ui-input-error")
        ]}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={described_by(@id || @name, @hint, @errors)}
        {@rest}
      />
      <p :if={@hint} id={"#{@id || @name}-hint"} class="ui-field-hint">{@hint}</p>
      <.field_errors base={@id || @name} errors={@errors} />
    </div>
    """
  end

  defp described_by(base, nil, errors), do: error_ids(base, errors)

  defp described_by(base, _hint, errors),
    do: Enum.join(["#{base}-hint" | List.wrap(error_ids(base, errors))], " ")

  attr :base, :string, required: true
  attr :errors, :list, required: true

  defp field_errors(assigns) do
    ~H"""
    <p
      :for={{msg, index} <- Enum.with_index(@errors)}
      id={error_id(@base, index)}
      class="ui-field-error"
    >
      <.icon name="hero-exclamation-circle-mini" class="size-4 shrink-0" />
      {msg}
    </p>
    """
  end

  defp error_id(base, index), do: "#{base}-error-#{index}"

  defp error_ids(_base, []), do: nil

  defp error_ids(base, errors) do
    errors
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {_msg, index} -> error_id(base, index) end)
  end

  @doc """
  Renders the page title, with an optional icon, subtitle and actions. It
  has no bottom border; the panel that follows owns its border.

  ## Examples

      <.header icon="hero-key">
        API keys
        <:subtitle>Keys authenticate API requests as you.</:subtitle>
        <:actions><.button variant="primary" size="sm">Create key</.button></:actions>
      </.header>
  """
  attr :icon, :string, default: nil
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class="flex flex-wrap items-center justify-between gap-4">
      <div class="flex min-w-0 items-center gap-3 sm:gap-4">
        <div :if={@icon} class="ui-header-icon">
          <.icon name={@icon} class="size-4 sm:size-5" />
        </div>
        <div class="min-w-0">
          <h1 class="text-base font-semibold text-base-content sm:text-lg">
            {render_slot(@inner_block)}
          </h1>
          <p :if={@subtitle != []} class="mt-0.5 text-sm text-muted">
            {render_slot(@subtitle)}
          </p>
        </div>
      </div>
      <div :if={@actions != []} class="flex shrink-0 flex-wrap items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  @doc """
  Renders a card section with an optional title.

  ## Examples

      <.panel title="Email" icon="hero-envelope">
        ...
      </.panel>
  """
  attr :title, :string, default: nil
  attr :icon, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :actions
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section class={["section-card", @class]} {@rest}>
      <header :if={@title} class="section-card-header">
        <.icon :if={@icon} name={@icon} class="size-4 shrink-0" />
        <h2>{@title}</h2>
        <div :if={@actions != []} class="ml-auto">{render_slot(@actions)}</div>
      </header>
      <div class="section-card-body">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  @doc """
  Renders a data table. Below `md` each row stacks into a card whose
  values are labelled by their column.

  Pass `empty` with an `:empty_state` slot to show an empty state in place
  of the table. It renders outside the stream container.

  Pass `span_from` (a function of the row returning a column index or nil)
  with a `:span` slot to replace a row's columns from that index on with
  one cell that spans them, such as a note for a row with nothing to
  show there. Below `md` the cell shows without a label.

  Pass `row_open` (a function of the row) with a `:details` slot to show a
  full-width row directly below each row for which it returns true, with
  the id `<row id>-details`. The caller owns the open state and the
  toggle that changes it. Below `md` the cell shows without a label.
  `row_open` is for list rows only: a stream tracks one DOM id per item, so
  a details row would be orphaned on delete or reset. Passing both raises.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="Id">{user.id}</:col>
        <:col :let={user} label="Username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"
  attr :empty, :boolean, default: false, doc: "whether there are no rows to show"

  attr :span_from, :any,
    default: nil,
    doc: "the function returning the column index a row's :span cell starts at, or nil"

  attr :row_open, :any,
    default: nil,
    doc: "the function returning whether a row's :details row is shown"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
    attr :class, :any
  end

  slot :action, doc: "the slot for showing user actions in the last table column"
  slot :empty_state, doc: "shown in place of the table when `empty` is true"
  slot :span, doc: "the cell that spans the columns from `span_from` on"
  slot :details, doc: "the full-width row shown below a row when `row_open` returns true"

  def table(%{rows: %Phoenix.LiveView.LiveStream{}, row_open: row_open}) when row_open != nil do
    raise ArgumentError, "table/1 row_open is for list rows only, not a stream"
  end

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div :if={@empty && @empty_state != []} class="list-table">
      {render_slot(@empty_state)}
    </div>
    <div :if={!@empty} class="list-table data-table">
      <table>
        <thead>
          <tr>
            <th :for={col <- @col}>{col[:label]}</th>
            <th :if={@action != []}>
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <%= for row <- @rows do %>
            <tr
              id={@row_id && @row_id.(row)}
              class={@row_click && "data-table-row-link"}
            >
              <td
                :for={col <- Enum.take(@col, span_index(@span_from, @row_item.(row), @col))}
                data-label={col[:label]}
                phx-click={@row_click && @row_click.(row)}
                class={col[:class]}
              >
                {render_slot(col, @row_item.(row))}
              </td>
              <td
                :if={span_index(@span_from, @row_item.(row), @col) < length(@col)}
                colspan={length(@col) - span_index(@span_from, @row_item.(row), @col)}
                data-label=""
              >
                {render_slot(@span, @row_item.(row))}
              </td>
              <td :if={@action != []} class="table-actions">
                <div class="flex justify-end gap-2">
                  <%= for action <- @action do %>
                    {render_slot(action, @row_item.(row))}
                  <% end %>
                </div>
              </td>
            </tr>
            <tr
              :if={@row_open && @row_open.(@row_item.(row))}
              id={@row_id && "#{@row_id.(row)}-details"}
              class="data-table-details"
            >
              <td colspan={length(@col) + if(@action != [], do: 1, else: 0)} data-label="">
                {render_slot(@details, @row_item.(row))}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  defp span_index(nil, _item, cols), do: length(cols)
  defp span_index(span_from, item, cols), do: span_from.(item) || length(cols)

  @doc """
  Renders label/value rows. Long values wrap.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <dl>
      <div :for={item <- @item} class="detail-row">
        <dt class="detail-label">{item.title}</dt>
        <dd class="detail-value">{render_slot(item)}</dd>
      </div>
    </dl>
    """
  end

  @doc """
  Renders a command or config sample that scrolls inside its own box.
  Each `:line` is a shell command shown after a prompt. Use `:source` for
  a file's contents, with `title` for its name.

  ## Examples

      <.code_block>
        <:line>goodflows run ci</:line>
      </.code_block>

      <.code_block title="goodflows.toml">
        <:source>{@config}</:source>
      </.code_block>
  """
  attr :title, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :line
  slot :source

  def code_block(assigns) do
    ~H"""
    <div class={["code-block", @class]} {@rest}>
      <div :if={@title} class="code-block-title">{@title}</div>
      <pre :if={@source != []} phx-no-format><code>{render_slot(@source)}</code></pre>
      <pre :if={@line != []} phx-no-format><code
        :for={line <- @line}
        class="code-block-prompt block"
      >{render_slot(line)}</code></pre>
    </div>
    """
  end

  @doc """
  Renders an empty state that says what is missing and offers the next
  action.

  ## Examples

      <.empty_state icon="hero-key" title="No API keys yet">
        Create a key to call the API from scripts and services.
        <:actions><.button variant="primary">Create key</.button></:actions>
      </.empty_state>
  """
  attr :icon, :string, default: nil
  attr :title, :string, default: nil
  attr :rest, :global
  slot :actions
  slot :inner_block, required: true

  def empty_state(assigns) do
    ~H"""
    <div class="ui-empty-state" {@rest}>
      <div :if={@icon} class="ui-empty-state-icon">
        <.icon name={@icon} class="size-7" />
      </div>
      <h2 :if={@title} class="text-sm font-semibold">{@title}</h2>
      <p class="mt-1 max-w-sm text-sm text-muted">{render_slot(@inner_block)}</p>
      <div :if={@actions != []} class="mt-5">{render_slot(@actions)}</div>
    </div>
    """
  end

  @doc """
  Groups the buttons at the end of a form.

  ## Examples

      <.form_actions>
        <.button variant="primary">Save password</.button>
      </.form_actions>
  """
  slot :inner_block, required: true

  def form_actions(assigns) do
    ~H"""
    <div class="ui-form-actions">{render_slot(@inner_block)}</div>
    """
  end

  @doc """
  Renders a menu that opens from a trigger and closes when focus leaves it.

  The inner block is the menu's `<li>` items; give links and buttons in
  them the `menu-item` class.

  ## Examples

      <.menu label="Your account" position="end">
        <:trigger>{@current_scope.user.email}</:trigger>
        <li><.link href={~p"/users/settings"} class="menu-item">Settings</.link></li>
      </.menu>
  """
  attr :label, :string, required: true, doc: "the accessible name of the trigger"
  attr :position, :string, default: "end", values: ~w(end top)
  attr :class, :any, default: nil
  attr :trigger_class, :any, default: nil
  attr :panel_class, :any, default: nil
  slot :trigger, required: true
  slot :inner_block, required: true

  def menu(assigns) do
    ~H"""
    <div class={["dropdown", "dropdown-#{@position}", @class]}>
      <div
        tabindex="0"
        role="button"
        aria-haspopup="true"
        aria-label={@label}
        class={["menu-trigger", @trigger_class]}
      >
        {render_slot(@trigger)}
      </div>
      <ul tabindex="0" class={["dropdown-content menu-panel", @panel_class]}>
        {render_slot(@inner_block)}
      </ul>
    </div>
    """
  end

  @doc """
  Renders a popover: a button that opens a small panel of content beside it,
  such as a quick form or details that don't need their own page or dialog.

  It is the browser's own popover (`popover="auto"`), so it needs no server
  round-trip to open or close: it opens from its trigger, closes on Escape,
  a click outside or the trigger again, sits in the top layer (never clipped
  by a scrolling pane or covered by a `z-index`), and the tab order runs from
  the trigger into it. The `.Popover` hook places it on its `side` of the
  trigger, flipping to the other side when there isn't room, and keeps it
  there while the page scrolls or resizes or its content changes. A LiveView
  patch keeps it open.

  The panel's id is `id` and the trigger's `<id>-trigger`. Put `autofocus` on
  a field inside to focus it on opening. To open or close it from a binding,
  use `show_popover/2`, `hide_popover/2` or `toggle_popover/2`, such as
  `phx-click={hide_popover("key-note")}` on a Cancel button; from the server,
  `push_event(socket, "gf:popover", %{id: "key-note", action: "hide"})`, such
  as after a save succeeds (so a form with errors stays open).

  To have the server follow the panel, give `on_open` and/or `on_close`:
  every time the panel actually opens or closes (from its trigger, Escape,
  a click outside, another popover opening or a binding), the hook pushes
  that event with no payload, to the LiveView or LiveComponent holding the
  `target` selector's element (or the panel's own). A nested popover's
  `toggle` and hide command bubble through this panel and are ignored. A
  panel still open when the LiveView reconnects pushes `on_open` again.
  Popovers without them push nothing. Use it to load content only while the
  panel is open.

  Use `menu/1` for a list of navigation links; use this for anything with a
  form or explanation in it.

  ## Examples

      <.popover id="key-note">
        <:trigger size="sm">Add note</:trigger>
        <:title>Key note</:title>
        <:description>Shown to everyone who can see this key.</:description>
        <.form for={@form} phx-submit="save_note">
          <.input field={@form[:note]} type="textarea" label="Note" autofocus />
          <.button variant="primary" size="sm">Save note</.button>
        </.form>
      </.popover>

      <.popover id="run-help" side="right" align="start">
        <:trigger variant="ghost" size="sm" aria-label="About required workflows">
          <.icon name="hero-information-circle" />
        </:trigger>
        A required workflow must pass before a change request can merge.
      </.popover>
  """
  attr :id, :string, required: true, doc: "the panel's id; the trigger's is `<id>-trigger`"

  attr :side, :string,
    default: "bottom",
    values: ~w(top right bottom left),
    doc: "the side of the trigger the panel opens on, when there is room"

  attr :align, :string,
    default: "center",
    values: ~w(start center end),
    doc: "the panel's alignment with the trigger along that side"

  attr :class, :any, default: "w-72", doc: "classes added to the panel's, such as a width"

  attr :width, :string,
    default: nil,
    values: [nil, "trigger"],
    doc: "`\"trigger\"` sizes the panel to the trigger's width, as a field's dropdown"

  attr :arrow, :boolean,
    default: true,
    doc: "whether an arrow points from the panel at the trigger"

  attr :for, :string,
    default: nil,
    doc:
      "the id of a control elsewhere the panel opens beside, in place of its own trigger: " <>
        "one panel shared by many controls, opened with a `\"gf:popover\"` push event"

  attr :on_open, :string,
    default: nil,
    doc: "an event pushed (no payload) each time the panel opens; nil pushes nothing"

  attr :on_close, :string,
    default: nil,
    doc: "an event pushed (no payload) each time the panel closes; nil pushes nothing"

  attr :show_on_mount, :boolean,
    default: false,
    doc:
      "open the panel as soon as it is added, for a panel the server renders only " <>
        "while it should be open"

  attr :restore_focus, :boolean,
    default: false,
    doc:
      "when the panel closes and focus is inside it or lost to the page, focus " <>
        "returns to its trigger. A click that already moved focus elsewhere keeps it"

  attr :target, :string,
    default: nil,
    doc:
      "a query selector of an element in the LiveView or LiveComponent that receives " <>
        "`on_open` and `on_close`; default the panel's own"

  attr :rest, :global, doc: "attributes added to the panel"

  slot :trigger, doc: "the trigger button's label (required without `for`)" do
    attr :variant, :string, doc: "a `button/1` variant; default `outline`"
    attr :size, :string, doc: "a `button/1` size"
    attr :icon, :string, doc: "a `button/1` leading icon"
    attr :class, :any, doc: "classes added to the button's, for layout only"
    attr :disabled, :boolean

    attr :refused, :string,
      doc:
        "why the panel can't open right now: the trigger stays focusable but reads as " <>
          "disabled, is described by the reason, and opens nothing"

    attr :title, :string, doc: "the button's tooltip"
    attr :"aria-label", :string
    attr :describedby, :string, doc: "the id of text that further describes the trigger"
  end

  slot :title, doc: "the panel's heading, which also names it"
  slot :description, doc: "a muted line under the title"
  slot :inner_block

  def popover(assigns) do
    trigger = List.first(assigns.trigger)
    refused = trigger && trigger[:refused]

    assigns =
      assign(assigns,
        trigger: trigger,
        refused: refused,
        trigger_attrs:
          trigger &&
            assigns_to_attributes(trigger, [
              :variant,
              :size,
              :icon,
              :class,
              :refused,
              :describedby
            ]),
        trigger_describedby:
          [refused && "#{assigns.id}-refused", trigger && trigger[:describedby]]
          |> Enum.filter(& &1)
          |> Enum.join(" ")
      )

    ~H"""
    <.button
      :if={@for == nil}
      id={"#{@id}-trigger"}
      type="button"
      popovertarget={!@refused && @id}
      aria-haspopup="dialog"
      aria-disabled={@refused && "true"}
      aria-describedby={@trigger_describedby != "" && @trigger_describedby}
      variant={@trigger[:variant] || "outline"}
      size={@trigger[:size] || "md"}
      icon={@trigger[:icon]}
      class={@trigger[:class]}
      {@trigger_attrs}
    >
      {render_slot(@trigger)}
    </.button>
    <span :if={@for == nil && @refused} id={"#{@id}-refused"} class="sr-only">{@refused}</span>
    <div
      id={@id}
      popover="auto"
      role="dialog"
      aria-labelledby={@title != [] && "#{@id}-title"}
      aria-describedby={@description != [] && "#{@id}-description"}
      phx-hook=".Popover"
      phx-mounted={JS.ignore_attributes(["style", "data-placement"])}
      data-trigger={@for || "#{@id}-trigger"}
      data-side={@side}
      data-align={@align}
      data-width={@width}
      data-on-open={@on_open}
      data-on-close={@on_close}
      data-show-on-mount={@show_on_mount && "true"}
      data-restore-focus={@restore_focus && "true"}
      data-event-target={@target}
      class={["popover-panel", @class]}
      {@rest}
    >
      <span
        :if={@arrow}
        id={"#{@id}-arrow"}
        class="popover-arrow"
        aria-hidden="true"
        phx-mounted={JS.ignore_attributes("style")}
      />
      <div :if={@title != [] || @description != []} class="popover-heading">
        <p :if={@title != []} id={"#{@id}-title"} class="popover-title">{render_slot(@title)}</p>
        <p :if={@description != []} id={"#{@id}-description"} class="popover-description">
          {render_slot(@description)}
        </p>
      </div>
      {render_slot(@inner_block)}
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Popover">
      // Places a native popover beside its trigger and reports opens and
      // closes to the server when asked. Events from a nested popover are
      // ignored, so closing one inside cannot close or report its parent.
      const GAP = 8
      const MARGIN = 8
      const ARROW = 10
      const ARROW_INSET = 12
      const OPPOSITE = {top: "bottom", bottom: "top", left: "right", right: "left"}

      export default {
        mounted() {
          this.place = () => this.position()
          this.resizeObserver = new ResizeObserver(this.place)
          // The browser closes the popover on Escape; a window-level binding (a dialog's) must not also run.
          this.onEscape = (e) => {
            if (e.key === "Escape" && this.el.matches(":popover-open")) e.stopPropagation()
          }

          this.el.addEventListener("beforetoggle", (e) => {
            if (e.target !== this.el) return
            if (e.newState === "open") requestAnimationFrame(this.place)
          })
          this.el.addEventListener("toggle", (e) => {
            if (e.target !== this.el) return
            if (e.newState === "open") { this.position(); this.follow() }
            else { this.unfollow(); this.restoreFocus() }
            this.report(e.newState)
          })
          this.el.addEventListener("gf:popover", (e) => {
            if (e.target !== this.el) return
            this.act(e.detail.action)
          })
          this.handleEvent("gf:popover", ({id, action}) => {
            if (id === this.el.id) this.act(action)
          })

          if (this.el.dataset.showOnMount === "true") this.act("show")
          else this.reportIfOpen()
        },

        // Reconnects remount the server while the browser may keep the popover open.
        reconnected() { this.reportIfOpen() },

        destroyed() { this.unfollow() },

        reportIfOpen() {
          if (this.el.matches(":popover-open")) this.report("open")
        },

        report(state) {
          const {onOpen, onClose, eventTarget} = this.el.dataset
          const event = state === "open" ? onOpen : onClose
          if (!event) return
          this.pushEventTo(eventTarget || this.el, event, {})
        },

        // Restore lost focus without overriding a deliberate click on another control.
        restoreFocus() {
          if (this.el.dataset.restoreFocus !== "true") return
          const active = document.activeElement
          if (active && active !== document.body && !this.el.contains(active)) return
          const trigger = document.getElementById(this.el.dataset.trigger)
          if (trigger) trigger.focus()
        },

        act(action) {
          if (action === "show") this.el.showPopover()
          else if (action === "hide") this.el.hidePopover()
          else this.el.togglePopover()
        },

        follow() {
          window.addEventListener("scroll", this.place, {capture: true, passive: true})
          window.addEventListener("resize", this.place, {passive: true})
          document.addEventListener("keydown", this.onEscape)
          this.resizeObserver.observe(this.el)
        },

        unfollow() {
          window.removeEventListener("scroll", this.place, {capture: true})
          window.removeEventListener("resize", this.place)
          document.removeEventListener("keydown", this.onEscape)
          this.resizeObserver.disconnect()
        },

        position() {
          const trigger = document.getElementById(this.el.dataset.trigger)
          if (!trigger || !this.el.matches(":popover-open")) return

          const t = trigger.getBoundingClientRect()
          if (this.el.dataset.width === "trigger") this.el.style.width = `${Math.round(t.width)}px`
          const p = this.el.getBoundingClientRect()
          const vw = document.documentElement.clientWidth
          const vh = document.documentElement.clientHeight
          const room = {top: t.top, bottom: vh - t.bottom, left: t.left, right: vw - t.right}
          const needed = (side) => (side === "top" || side === "bottom" ? p.height : p.width) + GAP + MARGIN

          const {side: preferred, align} = this.el.dataset
          let side = preferred
          if (room[side] < needed(side) && room[OPPOSITE[side]] > room[side]) side = OPPOSITE[side]

          const vertical = side === "top" || side === "bottom"
          const along = (start, size, panel) =>
            align === "start" ? start : align === "end" ? start + size - panel : start + (size - panel) / 2
          const clamp = (value, size, max) => Math.min(Math.max(value, MARGIN), Math.max(MARGIN, max - size - MARGIN))

          const top = vertical
            ? (side === "bottom" ? t.bottom + GAP : t.top - GAP - p.height)
            : along(t.top, t.height, p.height)
          const left = vertical
            ? along(t.left, t.width, p.width)
            : (side === "right" ? t.right + GAP : t.left - GAP - p.width)

          const placedTop = Math.round(clamp(top, p.height, vh))
          const placedLeft = Math.round(clamp(left, p.width, vw))
          this.el.style.top = `${placedTop}px`
          this.el.style.left = `${placedLeft}px`
          this.el.dataset.placement = side

          const arrow = document.getElementById(`${this.el.id}-arrow`)
          if (!arrow) return
          const pointAt = (middle, start, size) =>
            Math.round(Math.min(Math.max(middle - start - ARROW / 2, ARROW_INSET), size - ARROW_INSET - ARROW))
          // Arrow offsets start inside the border, at clientLeft and clientTop.
          arrow.style.left = vertical
            ? `${pointAt(t.left + t.width / 2, placedLeft + this.el.clientLeft, p.width)}px`
            : ""
          arrow.style.top = vertical
            ? ""
            : `${pointAt(t.top + t.height / 2, placedTop + this.el.clientTop, p.height)}px`
        },
      }
    </script>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com). This is the only way to
  render an icon.

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} aria-hidden="true" />
    """
  end

  @doc """
  Renders a modal dialog for a form or a message. The caller decides when
  it is shown, by rendering it conditionally, and names the event that
  closes it.

  Escape, the ESC button and a click outside the panel all push
  `on_cancel`. Keyboard focus moves into the dialog when it opens, stays
  inside it, and returns to the control that opened it when it closes.

  Put the closing buttons in `dialog_actions/1`. For a one-action
  confirmation use `confirm_dialog/1`.

  ## Examples

      <.editor_dialog :if={@show} id="create-key" title="Create API key" on_cancel="cancel">
        <.form for={@form} phx-submit="create">
          <.input field={@form[:name]} label="Name" />
          <.dialog_actions>
            <.button type="button" variant="ghost" phx-click="cancel">Cancel</.button>
            <.button variant="primary">Create key</.button>
          </.dialog_actions>
        </.form>
      </.editor_dialog>
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :on_cancel, :string, required: true, doc: "the event pushed when the dialog is dismissed"
  attr :size, :string, default: "md", values: ~w(sm md)
  slot :inner_block, required: true

  def editor_dialog(assigns) do
    ~H"""
    <div
      id={@id}
      class="modal-terminal"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
      phx-window-keydown={@on_cancel}
      phx-key="Escape"
      phx-hook=".DialogFocus"
      data-focus-first={"##{@id}-body"}
    >
      <div class="modal-backdrop-blur" aria-hidden="true" phx-click={@on_cancel}></div>
      <.focus_wrap id={"#{@id}-panel"} class={["modal-panel", "modal-panel-#{@size}"]}>
        <div class="modal-header">
          <h2 id={"#{@id}-title"} class="modal-title">{@title}</h2>
          <button
            type="button"
            class="modal-close-btn"
            aria-label={gettext("close")}
            phx-click={@on_cancel}
          >
            ESC
          </button>
        </div>
        <div id={"#{@id}-body"} class="modal-content">
          {render_slot(@inner_block)}
        </div>
      </.focus_wrap>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".DialogFocus">
      // Remembers the control that opened the dialog, moves focus to the
      // first control in the dialog body, and hands focus back on close.
      export default {
        mounted() {
          this.opener = document.activeElement;
          const body = this.el.querySelector(this.el.dataset.focusFirst);
          const first = body && body.querySelector(
            "input:not([type=hidden]), select, textarea, button, a[href], [tabindex]:not([tabindex='-1'])"
          );
          if (first) requestAnimationFrame(() => first.focus());
        },
        destroyed() {
          if (this.opener && this.opener.isConnected) this.opener.focus();
        }
      }
    </script>
    """
  end

  @doc """
  Groups the buttons at the end of an `editor_dialog/1`.
  """
  slot :inner_block, required: true

  def dialog_actions(assigns) do
    ~H"""
    <div class="modal-actions">{render_slot(@inner_block)}</div>
    """
  end

  @doc """
  Renders a confirmation with one action, built on `editor_dialog/1`. Use
  it instead of the browser's `data-confirm`.

  The confirm button's id is the dialog's id followed by `-confirm`.

  ## Examples

      <.confirm_dialog
        :if={@revoke_key}
        id="revoke-key"
        title="Revoke API key"
        confirm_label="Revoke key"
        on_confirm="revoke_key"
        on_cancel="cancel_revoke"
      >
        Anything using this key loses access immediately.
      </.confirm_dialog>
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :confirm_label, :string, required: true
  attr :on_confirm, :string, required: true, doc: "the event pushed by the confirm button"
  attr :on_cancel, :string, required: true, doc: "the event pushed when the dialog is dismissed"
  attr :destructive, :boolean, default: true
  slot :inner_block, required: true

  def confirm_dialog(assigns) do
    ~H"""
    <.editor_dialog id={@id} title={@title} on_cancel={@on_cancel} size="sm">
      <div class="text-sm">{render_slot(@inner_block)}</div>
      <.dialog_actions>
        <.button type="button" variant="ghost" phx-click={@on_cancel}>{gettext("Cancel")}</.button>
        <.button
          id={"#{@id}-confirm"}
          type="button"
          variant={if @destructive, do: "danger", else: "primary"}
          phx-click={@on_confirm}
        >
          {@confirm_label}
        </.button>
      </.dialog_actions>
    </.editor_dialog>
    """
  end

  @doc """
  Renders breadcrumbs for dashboard navigation. Below the `sm` breakpoint only
  the last two items show, and the earlier ones stay available to screen
  readers. The current page shrinks last, so its label stays whole.

  ## Examples

      <.breadcrumbs items={[
        %{label: "Dashboard", to: ~p"/dashboard/accounts/\#{@account.id}"},
        %{label: "API keys"}
      ]} />
  """
  attr :items, :list, required: true

  def breadcrumbs(assigns) do
    assigns = assign(assigns, :phone_from, length(assigns.items) - 2)

    ~H"""
    <nav aria-label="Breadcrumb" class="min-w-0">
      <ol class="flex min-w-0 items-center gap-2 font-mono text-xs text-muted">
        <li
          :for={{item, idx} <- Enum.with_index(@items)}
          class={[
            "flex min-w-0 items-center gap-2",
            idx < @phone_from && "sr-only focus-within:not-sr-only sm:not-sr-only",
            idx == @phone_from + 1 && "max-w-full shrink-0"
          ]}
        >
          <span
            :if={idx > 0}
            aria-hidden="true"
            class={idx == @phone_from && "hidden sm:inline"}
          >
            /
          </span>
          <.link
            :if={Map.has_key?(item, :to)}
            navigate={item.to}
            class="truncate transition-colors hover:text-base-content"
          >
            {item.label}
          </.link>
          <span
            :if={!Map.has_key?(item, :to)}
            aria-current="page"
            class="truncate text-base-content"
          >
            {item.label}
          </span>
        </li>
      </ol>
    </nav>
    """
  end

  ## JS Commands

  @doc "Shows the element matching `selector` with a fade/scale-in transition."
  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 150,
      transition:
        {"transition-all ease-out duration-150",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  @doc "Hides the element matching `selector` with a fade/scale-out transition."
  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 100,
      transition:
        {"transition-all ease-in duration-100", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc "Opens the `popover/1` with the given id."
  def show_popover(js \\ %JS{}, id), do: popover_action(js, id, "show")

  @doc "Closes the `popover/1` with the given id."
  def hide_popover(js \\ %JS{}, id), do: popover_action(js, id, "hide")

  @doc "Opens the `popover/1` with the given id, or closes it if it is open."
  def toggle_popover(js \\ %JS{}, id), do: popover_action(js, id, "toggle")

  defp popover_action(js, id, action),
    do: JS.dispatch(js, "gf:popover", to: "##{id}", detail: %{action: action})

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(GoodFlowsWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(GoodFlowsWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
