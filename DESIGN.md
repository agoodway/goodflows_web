# GoodFlows visual design system

Read this file before designing or changing UI in this repository. It is the
shared visual reference for human contributors and AI agents. Preserve the
established product identity when adding features or improving usability.

GoodFlows shares its identity with GoodIssues. The tokens, typefaces and
component vocabulary here are the same as in the GoodIssues dashboard, so the
two products read as one family. When the two guides disagree about a shared
rule, fix the disagreement instead of letting the apps drift apart.

## Identity and priorities

GoodFlows is a working tool for running checks, recording workflow runs and
test reports, and reviewing change requests. Its UI uses an **industrial
terminal** aesthetic: compact information, precise alignment, monospace
metadata, restrained surfaces, and green actions. The influences are
command-line interfaces, Bloomberg Terminal, Dieter Rams, and modern IDEs.

- Make status, hierarchy, and the next action easy to scan.
- Prefer consistent shared components over a distinctive treatment per feature.
- Use borders, spacing, and typography to separate information. Avoid
  decorative cards, oversized headings, heavy shadows, and large rounded
  containers.
- Keep the terminal vocabulary intentional: uppercase section labels, compact
  badges, slash-separated breadcrumbs, `// ` navigation group labels, `$ `
  command prompts, and technical metadata are established conventions. Body
  copy and action labels stay readable, plain language.
- Improve contrast, field boundaries, focus, and error feedback within this
  system. A usability fix should not introduce a new visual identity.

## The rule

The interface stays consistent because pages do not invent their own
controls. Before writing markup:

1. Look in `GoodFlowsWeb.CoreComponents` and `lib/good_flows_web/components/`.
2. If a component already covers the control or layout, use it.
3. If the same control or layout would appear in a second place, add it as a
   shared component and use that component in every place. Do not leave the
   first copy as one-off markup.

Hand-written daisyUI or Tailwind for a control the library already has is a
bug. A page may pass `class` to a component only to adjust layout (width,
margin), never to restyle a variant the component already defines.

## Where things live

| Source | Responsibility |
| --- | --- |
| [app/assets/css/app.css](app/assets/css/app.css) | Theme tokens, fonts, and the classes the shared components use |
| [CoreComponents](app/lib/good_flows_web/components/core_components.ex) | The app-wide primitives listed below. Imported once, in `html_helpers/0` in `good_flows_web.ex` |
| [Layouts](app/lib/good_flows_web/components/layouts.ex) | Public layout, dashboard shell, sidebar, theme toggle, flash group. Aliased in `html_helpers/0`. `<.flash_group>` is rendered only here |
| [AccountSwitcher](app/lib/good_flows_web/components/account_switcher.ex) | Account identity and switching at the foot of the sidebar |
| `lib/good_flows_web/components/<name>_components.ex` | One module per repeated feature, when one is needed. Not imported globally: call it as `<FeatureComponents.widget ...>` |

A feature module starts with `use Phoenix.Component` and
`import GoodFlowsWeb.CoreComponents`. Its `@moduledoc` lists each public
function and the pages that share it. A component that serves one page stays
in that page.

Explicit user direction takes precedence over this guide; general design
skills must adapt to the established app identity.

The components are written by hand on the theme tokens. daisyUI supplies
those tokens and the focus-driven `dropdown` behind `<.menu>`; no other
daisyUI component class appears in a template.

## Color system

Use semantic Tailwind tokens (`bg-base-100`, `text-base-content`,
`text-primary`, `border-base-300`) or their CSS variables. Keep the values in
OKLCH; do not invent hex substitutes.

| Token | Dark | Light | Role |
| --- | --- | --- | --- |
| `base-100` | `oklch(8% 0.01 270)` | `oklch(98% 0.005 90)` | Main surface |
| `base-200` | `oklch(6% 0.008 270)` | `oklch(95% 0.008 90)` | Secondary surface: sidebar, menus, code |
| `base-300` | `oklch(12% 0.012 270)` | `oklch(88% 0.012 90)` | Borders and separators |
| `base-content` | `oklch(92% 0.01 90)` | `oklch(15% 0.02 270)` | Main text |
| `primary` | `oklch(85% 0.18 145)` | `oklch(45% 0.2 145)` | Green primary actions and selection |
| `primary-content` | `oklch(10% 0.02 145)` | `oklch(98% 0.01 145)` | Text on primary actions |
| `info` | `oklch(70% 0.15 240)` | `oklch(50% 0.18 240)` | Informational state |
| `success` | `oklch(80% 0.2 145)` | `oklch(50% 0.22 145)` | Healthy or successful state |
| `warning` | `oklch(85% 0.18 85)` | `oklch(60% 0.2 85)` | Warning or pending state |
| `error` | `oklch(70% 0.22 25)` | `oklch(50% 0.25 25)` | Failure or destructive action |

Three derived variables keep both themes in step. Use them instead of
hard-coding a lightness per theme:

| Variable | Definition | Role |
| --- | --- | --- |
| `--line` | 12% `base-content` over `base-100` | Panel, table and menu borders |
| `--line-soft` | 7% `base-content` over `base-100` | Row dividers inside a panel |
| `--text-muted` | 65% `base-content` over `base-100` | Secondary text (`.text-muted`) |

Dark is the aesthetic reference; light is the complementary paper-like theme.
The configured default is light, with dark preference support. The root layout
resolves the system preference to an explicit `data-theme` of `light` or
`dark`, and keeps the person's choice in `data-theme-preference` (`system`,
`light` or `dark`). Theme switching must not leave a panel in the other theme:
the sidebar follows the theme like every other surface.

There is one accent. `primary` marks the main action, the current item,
links, selection, and focus. `info`, `warning` and `error` appear only in
notices, flashes, field errors and the error badge.

Templates contain no hex values and no Tailwind palette colors (`red-600`,
`black`). Use paired content tokens on colored backgrounds. Text meets 4.5:1
and focus rings meet 3:1 in both themes; the contrast test checks the
pairings the components use. A status shown in color is also written in words
or an accessible name.

## Typography

Both families are self-hosted variable fonts in `app/priv/static/fonts`,
declared with `@font-face` in `app.css`. The content security policy allows
only `font-src 'self'`, so a font loaded from a CDN will not render.

| Role | Treatment |
| --- | --- |
| Body and page titles | DM Sans (`font-sans`), system sans-serif fallback |
| Code, IDs, timestamps, metadata, breadcrumbs | JetBrains Mono (`font-mono`) |
| Shared buttons | JetBrains Mono, weight 500; 13px small / 14px medium |
| Standard page title | 16px on mobile / 18px from `sm`, semibold |
| Page subtitle | 14px, muted; wrap a slug or ID in `<code>` |
| Section card heading | Monospace, 11px, weight 600, uppercase, `0.05em` tracking |
| Table column heading | Monospace, 11px, weight 600, uppercase, `0.08em` tracking |
| Detail labels and values | 12px; muted labels, stronger values |
| Status badges | Monospace, 11px, weight 600, uppercase |

Keep small metadata secondary; do not use tiny captions for essential
guidance. Do not introduce another font family. Use sentence case for prose
and actions ("Create key", "API keys"); let heading and badge styles apply
uppercase. Show timestamps in monospace as `YYYY-MM-DD HH:MM UTC`.

Write every label in sentence case in the template, including badge text,
table headers and panel titles. Button text is never all caps. The uppercase
seen on panel titles, table headers, badges and dialog titles is applied by
CSS (`text-transform`), so the accessible text stays sentence case.

## Layout, surfaces, and spacing

- The dashboard shell is a sidebar, a top bar with breadcrumbs, the theme
  toggle and the signed-in user's menu, then content on the subtle grid
  background (`.bg-grid`). Below 1024px the sidebar becomes a drawer.
- The sidebar holds the brand mark, navigation grouped under `// ` labels,
  and the account switcher at its foot.
- Main content uses 16px padding, increasing to 24px at `lg`, in a column of
  at most `max-w-5xl`. Public pages (home, log in, settings) use the public
  layout with a `max-w-2xl` column.
- Page headers have no bottom border; the panel that follows owns its border.
- Use the spacing rhythm 4, 8, 12, 16, 24, and 32px. Match the surrounding
  component instead of introducing arbitrary gaps.
- Panels and tables have a 1px `--line` border and a 6px radius; panels add a
  lightly tinted header and 16px body padding. Shared
  buttons and modals have a 4px radius. Tags, badges, navigation items, menus
  and code samples use 2px. Form fields use square corners. These differences
  are deliberate.
- Detail rows align labels left and values right with a soft divider. Long
  values wrap without displacing adjacent actions.
- Shadows appear only on things that float: menus, flash messages, modals.
- Stack columns on small screens. Tables become label/value rows below `md`.
  Wide code scrolls inside its own box, never the page.

## Shared components

Every one of these is in `GoodFlowsWeb.CoreComponents` unless noted.

| Component | Use it for | Replaces |
| --- | --- | --- |
| `icon/1` | Every icon, as `<.icon name="hero-x-mark" />` | Heroicons modules, inline SVG |
| `button/1` | Every button and button-like link. Variants `primary`, `soft`, `ghost`, `outline`, `danger`; `size="sm"`; optional `icon` | `btn btn-primary` and other `btn` classes |
| `text_link/1` | A link inside running text | `text-primary hover:underline` on a `<.link>` |
| `input/1` | Every form field | `input`, `select`, `textarea` classes and hand-written error lines |
| `header/1` | Page title, optional icon, subtitle, actions | A hand-written `<h1>` row |
| `panel/1` | Every card section, with an optional title and icon | `card`, bordered `div` sections |
| `table/1` | Every data table, including its empty state | `table table-zebra`, hand-written `<table>` |
| `list/1` | Label/value rows | Hand-written `<dl>` or flex rows |
| `status_badge/1` | Every status. Kinds `neutral`, `primary`, `error`; optional `dot` | `badge badge-*` |
| `tag/1` | A short literal value that keeps its casing: a key prefix, a step number | `<code class="...">` chips |
| `notice/1` | A message that stays on the page. Kinds `neutral`, `info`, `warning` | `alert alert-*` |
| `flash/1`, `Layouts.flash_group/1` | Transient messages | `toast`, `alert` |
| `editor_dialog/1`, `dialog_actions/1` | Every modal form or message | `modal modal-open`, `modal-box`, `modal-action` |
| `confirm_dialog/1` | Every one-action confirmation | `data-confirm`, a hand-built confirm modal |
| `menu/1` | A menu opened from a trigger | Hand-written `dropdown` markup |
| `popover/1` | A quick form or explanation beside a control, opened from its trigger | Hand-built floating panels, `dropdown` markup holding forms |
| `code_block/1` | Shell commands and config files | `<pre>` blocks |
| `empty_state/1` | Empty results, with the action that fills them | Centered placeholder text |
| `form_actions/1` | The button row at the end of a form | A hand-written flex row |
| `breadcrumbs/1` | The top bar trail, fed by the LiveView's `breadcrumbs` assign | A hand-written trail |

Button variants:

- `primary`: the one main action of a page or dialog.
- `soft`: the default, for secondary actions.
- `ghost`: quiet row and header actions, and Cancel.
- `outline`: quiet bordered actions such as pagers and retries.
- `danger`: the confirm button of a destructive dialog. A row's "Revoke" or
  "Delete" is `ghost`; it opens the dialog that holds the `danger` button.

Preserve link versus button semantics, LiveView events, disabled states, and
permission checks.

`input/1` keeps the label visible, draws a clear boundary, and puts each
error under its field with an icon and words. Each error line has an id that
the field names in `aria-describedby`. Prefer the defaults; a custom `class`
replaces the default classes and requires complete styling. Do not use a
placeholder as the only label.

`table/1` has row rules and no zebra striping. Rows react to the pointer only
when they can be clicked. Below `md` each row stacks into label/value pairs.
Pass `empty` with an `:empty_state` slot; the empty state renders outside the
stream container. To replace a row's trailing columns with one note, such as a
required workflow with no run, pass `span_from` (a function of the row that
returns a column index, or nil for a normal row) with a `:span` slot; the slot
renders in one cell spanning the columns from that index on, and below `md` it
shows without a label. To show more about a row on demand, pass `row_open`
(a function of the row that returns whether it is open) with a `:details`
slot; an open row gets a full-width row directly below it, id
`<row id>-details`, on a lightly tinted surface, and below `md` it shows
without a label. `row_open` is for list rows only: a stream tracks one DOM
id per item, so a details row would be orphaned on delete or reset, and
`table/1` raises if `rows` is a stream. The page owns the open state and
puts the toggle, a `ghost` icon button with `aria-expanded`, `aria-controls`
naming the details row while it is open (and no `aria-controls` while it is
closed, since the row does not exist then) and an accessible name naming the
row, in the row's first column. Do not hand-write `colspan` cells in a page.

Uploaded Markdown, such as a scenario's steps from its set file, renders
through `GoodFlowsWeb.ScenarioMarkdown` (MDEx with raw HTML off, then
html_sanitize_ex) inside a `.scenario-markdown` block. The class styles the
sanitized tags in this system's terms, with no typography plugin: list
markers and indents, paragraph spacing, `code` and `pre` in the tag style
(2px radius, monospace) with `pre` scrolling inside its own box, tables in
the data table border style, and links in the `text_link/1` color. Use it for
any rendered Markdown; never `raw/1` anything that has not passed the
sanitizer.

Image evidence (an unexpired artifact whose content type is `image/*`) shows
as an `.evidence-gallery` strip: each `.evidence-shot` is an `.evidence-thumb`
button with its file name under it as an `.evidence-caption`, next to a
download icon link. Other evidence is a list of names, each with the same
download icon (`hero-arrow-down-tray`, labelled `Download <path>`, in the
neutral `.evidence-download` color rather than the link accent) or
`Expired`. Neither shows content
types or sizes. The strip scrolls sideways with scroll snap, and its
thumbnails are narrow enough that the next one peeks in at 400px. A
thumbnail opens an `editor_dialog/1` of size `lg` showing the image whole
(`.evidence-full`), with previous and next buttons, the arrow keys, and an
`Open original` link. Images load through the members-only download route;
the CSP allows the object store's origin in `img-src` for its redirect.

A dialog is rendered conditionally by its LiveView and names the event that
closes it. Escape, the ESC button and a click outside the panel all push that
event. Focus moves to the first control in the dialog body when it opens,
stays inside the dialog, and returns to the control that opened it on close.
The dialog header is a plain title bar; the window-control dots, glow border
and scanlines of the GoodIssues modal are intentionally left out here.

`popover/1` is the browser's own popover (`popover="auto"`): its trigger is
an `outline` `<.button>` unless the `:trigger` slot names another variant,
and it opens a `base-200` panel with a `--line` border, 2px radius and a menu
shadow, with an optional `:title` (styled as a section heading) and muted
`:description`. It opens and closes on the client (Escape and a click
outside close it) and sits above everything. The `.Popover` hook places it
on its `side` (`align` along it), flips it when there isn't room, keeps it
inside the viewport, and points a small arrow at the trigger. Close it with
`hide_popover/2` or a `"gf:popover"` push event. `for` lets one panel serve
many controls. `on_open` and `on_close` push events so the server can load
content only while it is open. A trigger with `refused` stays focusable but
reads as disabled, is described by the reason, and opens nothing. Use
`menu/1` for lists of links and `editor_dialog/1` for anything that needs
the page's full attention.

Shared components own presentation, while their callers own resource state,
permissions, URLs, and event handling.

## Writing

- Name things as the person using them would: "API keys", "Read only", not
  internal type names.
- A button says what it does and keeps that name through the flow: "Create
  key" opens a dialog whose confirm button is "Create key".
- Errors say what went wrong and what to do next. They do not apologize.
- An empty state says what is missing and offers the action that fills it.
- Number steps only when the order matters.

## Interaction and accessibility

- Preserve visible keyboard focus: a 2px primary outline with a 2px offset on
  every interactive element. Never use `outline-none` without another
  visible ring.
- Every page starts with a "Skip to main content" link to `<main id="main">`.
  The root layout renders the link; each layout owns its `<main>`.
- Every page works at 400px wide without horizontal page scroll.
- Hover styles go only on things that can be clicked.
- Give icon-only actions an accessible name. Name repeated row actions after
  their row ("Revoke Production worker").
- Use short color and border transitions of 80–150ms. Do not add ambient
  animation; the reduced-motion rule in `app.css` must keep working.
- The closed mobile drawer is hidden from the tab order; opening it moves
  focus into it and Escape closes it.
- Keep feedback specific: identify errors, show saving states with
  `phx-disable-with`, and prevent duplicate submissions.

## Before completing a UI change

1. Read this guide and the relevant shared components before choosing styles.
2. Match a comparable existing screen; reuse its hierarchy and component
   variants.
3. Keep new shared CSS in `@layer components` so utility classes can override
   it. Follow [app/AGENTS.md](app/AGENTS.md) for Phoenix CSS and component
   conventions.
4. Inspect desktop and mobile, light and dark, and system theme behavior.
   Check long content, empty states, validation, and keyboard focus where the
   change affects them. In development the Tidewave toolbar sits over the
   foot of the sidebar; move or hide it to see the account switcher.
5. Run `mix precommit`. It includes the two guards in
   `app/test/good_flows_web/design/`: `contrast_test.exs` reads the theme
   tokens and fails when a text or focus pairing drops below AA, and
   `visual_system_test.exs` fails on hex or palette colors and on
   hand-written `btn`, `badge`, `modal`, `alert` or `data-confirm` markup.
   For visual work, inspect the rendered result as well as the code, and
   report any verification limits.
6. Update this guide when an approved change alters the shared design system.
   A one-off implementation must not silently redefine the app's style.
