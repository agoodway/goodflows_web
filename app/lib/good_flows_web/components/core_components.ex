defmodule GoodFlowsWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  Styling follows the design system in `DESIGN.md` at the repository root:
  the classes used here (`ui-button`, `ui-input`, `status-badge`, ...) are
  defined in `assets/css/app.css`. Use `icon/1` for
  [Heroicons](https://heroicons.com).

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

  Use `primary` for the main action, `soft` for supporting emphasis,
  `subtle` for secondary actions, and `danger` for destructive ones.

  ## Examples

      <.button>Send</.button>
      <.button phx-click="go" variant="primary">Send</.button>
      <.button navigate={~p"/"} variant="subtle" size="sm">Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled type)
  attr :class, :any, default: nil
  attr :variant, :string, default: "soft", values: ~w(primary soft subtle danger)
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
  Renders a status badge. Always put the status in the label: the tone
  colour only supports it.

  ## Examples

      <.badge tone="active" dot>Active</.badge>
  """
  attr :tone, :string, default: "muted", values: ~w(active pending revoked info muted error)
  attr :dot, :boolean, default: false
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class={["status-badge", "status-badge-#{@tone}"]}>
      <span :if={@dot} aria-hidden="true" class="size-1.5 rounded-full bg-current"></span>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
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
          {@rest}
        />{@label}
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="ui-field">
      <label :if={@label} for={@id} class="ui-field-label">{@label}</label>
      <select
        id={@id}
        name={@name}
        class={[@class || "ui-input ui-select", @errors != [] && (@error_class || "ui-input-error")]}
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Form.options_for_select(@options, @value)}
      </select>
      <.error :for={msg <- @errors}>{msg}</.error>
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
        {@rest}
      >{Form.normalize_value("textarea", @value)}</textarea>
      <.error :for={msg <- @errors}>{msg}</.error>
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
        {@rest}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="ui-field-error">
      <.icon name="hero-exclamation-circle-mini" class="size-4 shrink-0" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-base font-semibold sm:text-lg">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-1 text-sm text-muted">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div :if={@actions != []} class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="list-table data-table">
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
          <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
            <td
              :for={col <- @col}
              data-label={col[:label]}
              phx-click={@row_click && @row_click.(row)}
              class={@row_click && "hover:cursor-pointer"}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="table-actions">
              <div class="flex justify-end gap-2">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a data list.

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
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  @doc """
  Renders a modal dialog. The caller decides when it is shown, by rendering
  it conditionally, and names the event that closes it.

  Escape, the ESC button and a click outside the panel all push `on_cancel`.
  Keyboard focus moves into the dialog when it opens and stays inside it.
  Put the closing buttons in a `<div class="modal-actions">`.

  ## Examples

      <.modal :if={@show} id="confirm-modal" title="Revoke key" on_cancel="cancel">
        <p>Anything using this key loses access immediately.</p>
        <div class="modal-actions">
          <.button variant="subtle" phx-click="cancel">Cancel</.button>
          <.button variant="danger" phx-click="revoke">Revoke key</.button>
        </div>
      </.modal>
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :on_cancel, :string, required: true, doc: "the event pushed when the modal is dismissed"
  attr :size, :string, default: "md", values: ~w(sm md)
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      class="modal-terminal"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
      phx-window-keydown={@on_cancel}
      phx-key="Escape"
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
        <div class="modal-content" phx-mounted={JS.focus_first()}>
          {render_slot(@inner_block)}
        </div>
      </.focus_wrap>
    </div>
    """
  end

  @doc """
  Renders breadcrumbs for dashboard navigation.

  ## Examples

      <.breadcrumbs items={[
        %{label: "Companies", to: ~p"/dashboard/accounts/\#{@account.id}/companies"},
        %{label: "Acme Corp"}
      ]} />
  """
  attr :items, :list, required: true

  def breadcrumbs(assigns) do
    ~H"""
    <nav aria-label="Breadcrumb" class="min-w-0">
      <ol class="flex min-w-0 items-center gap-2 font-mono text-xs text-muted">
        <li :for={{item, idx} <- Enum.with_index(@items)} class="flex min-w-0 items-center gap-2">
          <span :if={idx > 0} aria-hidden="true" class="text-base-content/25">/</span>
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
