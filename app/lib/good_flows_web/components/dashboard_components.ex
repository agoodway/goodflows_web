defmodule GoodFlowsWeb.DashboardComponents do
  @moduledoc """
  Shared page structure: page headers, sections, label/value rows, command
  samples and empty states. These own presentation only; callers own
  resource state, permissions, URLs and events. See `DESIGN.md`.
  """
  use Phoenix.Component

  import GoodFlowsWeb.CoreComponents, only: [icon: 1]

  @doc """
  Renders the page identity: an icon, the title, a subtitle and the page's
  actions. It has no bottom border; the panel that follows owns its border.

  ## Examples

      <.page_header icon="hero-key">
        <:title>API keys</:title>
        <:subtitle>Keys authenticate API requests as you.</:subtitle>
        <:actions><.button variant="primary">Create key</.button></:actions>
      </.page_header>
  """
  attr :icon, :string, default: nil
  attr :rest, :global
  slot :title, required: true
  slot :subtitle
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header class="flex flex-wrap items-center justify-between gap-4" {@rest}>
      <div class="flex min-w-0 items-center gap-3 sm:gap-4">
        <div
          :if={@icon}
          class="flex size-9 shrink-0 items-center justify-center rounded-sm border border-primary/20 bg-primary/10 sm:size-10"
        >
          <.icon name={@icon} class="size-4 text-primary sm:size-5" />
        </div>
        <div class="min-w-0">
          <h1 class="truncate text-base font-semibold text-base-content sm:text-lg">
            {render_slot(@title)}
          </h1>
          <p :if={@subtitle != []} class="mt-0.5 font-mono text-[11px] text-muted sm:text-xs">
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
  Renders a bordered section with a heading and slotted content.

  ## Examples

      <.section_card icon="hero-envelope">
        <:title>Email</:title>
        ...
      </.section_card>
  """
  attr :icon, :string, default: nil
  attr :tone, :string, default: "default", values: ~w(default error info)
  attr :class, :any, default: nil
  attr :body_class, :any, default: nil
  attr :rest, :global
  slot :title, required: true
  slot :actions
  slot :inner_block, required: true

  def section_card(assigns) do
    ~H"""
    <section class={["section-card", @class]} {@rest}>
      <header class={["section-card-header", "section-card-header-#{@tone}"]}>
        <.icon :if={@icon} name={@icon} class="size-4 shrink-0" />
        <h2>{render_slot(@title)}</h2>
        <div :if={@actions != []} class="ml-auto">{render_slot(@actions)}</div>
      </header>
      <div class={["section-card-body", @body_class]}>{render_slot(@inner_block)}</div>
    </section>
    """
  end

  @doc "Renders a label/value row. Long values wrap."
  attr :rest, :global
  slot :label, required: true
  slot :inner_block, required: true

  def detail_row(assigns) do
    ~H"""
    <div class="detail-row" {@rest}>
      <span class="detail-label">{render_slot(@label)}</span>
      <div class="detail-value">{render_slot(@inner_block)}</div>
    </div>
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
  action. Use `compact` inside a section and the full size for a page.
  """
  attr :icon, :string, default: nil
  attr :compact, :boolean, default: false
  attr :rest, :global
  slot :title
  slot :actions
  slot :inner_block, required: true

  def empty_state(assigns) do
    ~H"""
    <div
      class={[
        "flex flex-col items-center justify-center px-4 text-center",
        if(@compact, do: "py-8", else: "py-16")
      ]}
      {@rest}
    >
      <div
        :if={@icon}
        class={
          if @compact,
            do: "mb-2",
            else:
              "mb-5 flex size-14 items-center justify-center rounded-sm border border-base-300 bg-base-200"
        }
      >
        <.icon name={@icon} class="size-7 text-muted" />
      </div>
      <h2 :if={@title != []} class="text-sm font-semibold">{render_slot(@title)}</h2>
      <p class="mt-1 max-w-sm text-sm text-muted">{render_slot(@inner_block)}</p>
      <div :if={@actions != []} class={if @compact, do: "mt-3", else: "mt-5"}>
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc "Groups the save and cancel actions at the end of a form."
  slot :inner_block, required: true

  def form_actions(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-end gap-3 border-t border-base-300/50 pt-4">
      {render_slot(@inner_block)}
    </div>
    """
  end
end
