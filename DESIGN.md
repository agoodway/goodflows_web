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

## Scope and source of truth

| Source | Responsibility |
| --- | --- |
| [app/assets/css/app.css](app/assets/css/app.css) | Theme tokens, fonts, navigation, surfaces, shared component styles |
| [CoreComponents](app/lib/good_flows_web/components/core_components.ex) | Buttons, inputs, badges, icons, flash, modal, table, breadcrumbs |
| [DashboardComponents](app/lib/good_flows_web/components/dashboard_components.ex) | Page headers, section cards, detail rows, command samples, empty states, form actions |
| [Layouts](app/lib/good_flows_web/components/layouts.ex) | Public layout, dashboard shell, sidebar, theme toggle |
| [AccountSwitcher](app/lib/good_flows_web/components/account_switcher.ex) | Account identity and switching at the foot of the sidebar |

Use the shared component implementation for exact dimensions and behavior. If
a shared pattern needs improvement, update it centrally and inspect its
existing users. Explicit user direction takes precedence over this guide;
general design skills must adapt to the established app identity.

Write components by hand with Tailwind utilities and the classes in `app.css`.
daisyUI supplies the theme tokens and the focus-driven `dropdown`; do not add
other daisyUI components (`btn`, `badge`, `modal`, `alert`, `input`, `table`).

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

Use paired content tokens on colored backgrounds. Check the real contrast of
muted text and subtle borders. Color supplements a visible status label or
icon; it never carries meaning alone.

## Typography

Both families are self-hosted variable fonts in `app/priv/static/fonts`,
declared with `@font-face` in `app.css`. The content security policy allows
only `font-src 'self'`, so a font loaded from a CDN will not render.

| Role | Treatment |
| --- | --- |
| Body and page titles | DM Sans (`font-sans`), system sans-serif fallback |
| Code, IDs, timestamps, metadata, breadcrumbs | JetBrains Mono (`font-mono`) |
| Shared buttons | JetBrains Mono, weight 500; 12px small / 14px medium |
| Standard page title | 16px on mobile / 18px from `sm`, semibold |
| Page subtitle | Monospace, 11px on mobile / 12px from `sm`, muted |
| Section card heading | Monospace, 11px, weight 600, uppercase, `0.05em` tracking |
| Table column heading | Monospace, 11px, weight 600, uppercase, `0.08em` tracking |
| Detail labels and values | 12px; muted labels, stronger values |
| Status badges | Monospace, 11px, weight 600, uppercase |

Keep small metadata secondary; do not use tiny captions for essential
guidance. Do not introduce another font family. Use sentence case for prose
and actions ("Create key", "API keys"); let heading and badge styles apply
uppercase. Show timestamps in monospace as `YYYY-MM-DD HH:MM UTC`.

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
- Section cards and list tables have a 1px `--line` border and a 6px radius;
  section cards add a lightly tinted header and 16px body padding. Shared
  buttons and modals have a 4px radius. Tags, badges, navigation items, menus
  and code samples use 2px. Form fields use square corners. These differences
  are deliberate.
- Detail rows align labels left and values right with a soft divider. Long
  values wrap without displacing adjacent actions.
- Shadows appear only on things that float: menus, flash messages, modals.
- Stack columns on small screens. Tables become label/value rows below `md`.
  Wide code scrolls inside its own box, never the page.

## Component rules

| UI need | Reuse |
| --- | --- |
| Actions and navigation buttons | `CoreComponents.button`: `primary`, `soft`, `subtle`, `danger`; sizes `sm`, `md`; optional `icon` |
| Labeled form controls and errors | `CoreComponents.input` |
| Icons | `CoreComponents.icon` with `hero-*` names |
| Status | `CoreComponents.badge`: tones `active`, `pending`, `revoked`, `info`, `muted`, `error` |
| Short code-like values (key prefixes, counts) | `.tag-badge` |
| Dialogs | `CoreComponents.modal`, with a `.modal-actions` row |
| Tabular data | `CoreComponents.table`, or `.list-table.data-table` around a hand-written table with `data-label` cells |
| Page identity and actions | `DashboardComponents.page_header` |
| Content sections and label/value pairs | `section_card`, `detail_row` |
| Shell commands and config files | `code_block` |
| Save/cancel rows | `form_actions` |
| Empty results | `empty_state` |
| Top bar trail | `CoreComponents.breadcrumbs`, fed by the LiveView's `breadcrumbs` assign |

Use a green `primary` button for the main action, `soft` for supporting
emphasis, `subtle` for secondary actions, and `danger` for destructive ones.
One `primary` button per view or dialog. Preserve link versus button
semantics, LiveView events, disabled states, and permission checks.

Keep field labels visible, give inputs clear boundaries, and place validation
messages beside their fields. Prefer the shared input's defaults; a custom
`class` replaces its default classes and requires complete styling. Do not
use a placeholder as the only label.

A modal is rendered conditionally by its LiveView and names the event that
closes it. Escape, the ESC button and a click outside the panel all push that
event. Focus moves to the first control in the dialog body when it opens and
stays inside the dialog until it closes. The modal header is a plain title bar; the window-control dots, glow
border and scanlines of the GoodIssues modal are intentionally left out here.

Shared components own presentation, while their callers own resource state,
permissions, URLs, and event handling. Add explicit, reusable variants only
when needed; do not copy a component and retheme it for a single screen.

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
  links, buttons and fields.
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
5. Run `mix precommit`. For visual work, inspect the rendered result as well
   as the code, and report any verification limits.
6. Update this guide when an approved change alters the shared design system.
   A one-off implementation must not silently redefine the app's style.
