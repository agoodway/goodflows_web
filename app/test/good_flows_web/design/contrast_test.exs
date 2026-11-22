defmodule GoodFlowsWeb.Design.ContrastTest do
  @moduledoc """
  Reads the theme tokens from `assets/css/app.css` and checks the text and
  focus pairings the shared components rely on against WCAG AA: 4.5:1 for
  text, 3:1 for focus rings.
  """
  use ExUnit.Case, async: true

  @css File.read!(Path.expand("../../../assets/css/app.css", __DIR__))
  @themes ~w(dark light)

  # {description, foreground, background}. A background of `{:tint, token, percent}`
  # is that token at `percent` opacity over base-100, as the components draw it.
  @text_pairs [
    {"body text on the main surface", "base-content", "base-100"},
    {"body text on the secondary surface", "base-content", "base-200"},
    {"muted text on the main surface", :muted, "base-100"},
    {"muted text on the secondary surface", :muted, "base-200"},
    {"placeholder text in a field", :placeholder, "base-100"},
    {"links on the main surface", "primary", "base-100"},
    {"links on the secondary surface", "primary", "base-200"},
    {"primary button label", "primary-content", "primary"},
    {"soft button label", "primary", {:tint, "primary", 10}},
    {"active navigation item", "primary", {:tint, "primary", 12, "base-200"}},
    {"field error text", "error", "base-100"},
    {"danger button label", "error", {:tint, "error", 10}},
    {"neutral status badge", {:badge, :muted}, {:tint, :muted, 12}},
    {"primary status badge", {:badge, "primary"}, {:tint, "primary", 12}},
    {"error status badge", {:badge, "error"}, {:tint, "error", 12}}
  ]

  @focus_pairs [
    {"focus ring on the main surface", "primary", "base-100"},
    {"focus ring on the secondary surface", "primary", "base-200"}
  ]

  for theme <- @themes do
    for {label, fg, bg} <- @text_pairs do
      test "#{theme}: #{label} meets 4.5:1" do
        assert_contrast(unquote(theme), unquote(Macro.escape(fg)), unquote(Macro.escape(bg)), 4.5)
      end
    end

    for {label, fg, bg} <- @focus_pairs do
      test "#{theme}: #{label} meets 3:1" do
        assert_contrast(unquote(theme), unquote(Macro.escape(fg)), unquote(Macro.escape(bg)), 3.0)
      end
    end
  end

  defp assert_contrast(theme, fg, bg, minimum) do
    tokens = tokens(theme)
    ratio = contrast(resolve(fg, tokens), resolve(bg, tokens))

    assert ratio >= minimum,
           "#{inspect(fg)} on #{inspect(bg)} in the #{theme} theme is " <>
             "#{Float.round(ratio, 2)}:1, below #{minimum}:1"
  end

  # --- Reading app.css ---

  defp tokens(theme) do
    [_, block] = Regex.run(~r/name: "#{theme}";(.*?)\n}/s, @css)

    ~r/--color-([a-z0-9-]+): oklch\(([\d.]+)% ([\d.]+) ([\d.]+)\);/
    |> Regex.scan(block)
    |> Map.new(fn [_, name, l, c, h] -> {name, {to_float(l) / 100, to_float(c), to_float(h)}} end)
  end

  # The share of base-content in a `color-mix(..., var(--color-base-content) N%, ...)`.
  defp content_share(pattern) do
    [_, percent] = Regex.run(pattern, @css)
    to_float(percent) / 100
  end

  defp to_float(string) do
    {float, ""} = Float.parse(string)
    float
  end

  # --- Resolving a pairing to linear RGB ---

  defp resolve(:muted, tokens) do
    share =
      content_share(~r/--text-muted: color-mix\(in oklch, var\(--color-base-content\) (\d+)%/)

    to_rgb(mix(tokens["base-content"], tokens["base-100"], share))
  end

  defp resolve(:placeholder, tokens) do
    share =
      content_share(
        ~r/\.ui-input::placeholder \{ color: color-mix\(in oklch, var\(--color-base-content\) (\d+)%/
      )

    to_rgb(mix(tokens["base-content"], tokens["base-100"], share))
  end

  # Badge text is 85% of its tone mixed with the body text colour.
  defp resolve({:badge, tone}, tokens) do
    to_rgb(mix(oklch(tone, tokens), tokens["base-content"], 0.85))
  end

  defp resolve({:tint, tone, percent}, tokens),
    do: resolve({:tint, tone, percent, "base-100"}, tokens)

  defp resolve({:tint, tone, percent, surface}, tokens) do
    over(resolve(tone, tokens), resolve(surface, tokens), percent / 100)
  end

  defp resolve(token, tokens) when is_binary(token), do: to_rgb(Map.fetch!(tokens, token))

  defp oklch(:muted, tokens) do
    share =
      content_share(~r/--text-muted: color-mix\(in oklch, var\(--color-base-content\) (\d+)%/)

    mix(tokens["base-content"], tokens["base-100"], share)
  end

  defp oklch(token, tokens), do: Map.fetch!(tokens, token)

  # --- Colour maths ---

  # color-mix(in oklch, a share, b): interpolate lightness and chroma, and
  # hue along the shorter arc.
  defp mix({l1, c1, h1}, {l2, c2, h2}, share) do
    delta = h2 - h1

    delta =
      cond do
        delta > 180 -> delta - 360
        delta < -180 -> delta + 360
        true -> delta
      end

    {l1 * share + l2 * (1 - share), c1 * share + c2 * (1 - share), h1 + delta * (1 - share)}
  end

  # OKLCH to linear sRGB, clamped to the displayable range.
  defp to_rgb({l, c, h}) do
    a = c * :math.cos(h * :math.pi() / 180)
    b = c * :math.sin(h * :math.pi() / 180)

    l_ = :math.pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
    m_ = :math.pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
    s_ = :math.pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)

    {
      clamp(4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_),
      clamp(-1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_),
      clamp(-0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_)
    }
  end

  defp clamp(value), do: value |> max(0.0) |> min(1.0)

  # Alpha-composites `top` over `bottom`. Browsers blend in gamma-encoded sRGB.
  defp over({r1, g1, b1}, {r2, g2, b2}, alpha) do
    blend = fn top, bottom -> decode(encode(top) * alpha + encode(bottom) * (1 - alpha)) end
    {blend.(r1, r2), blend.(g1, g2), blend.(b1, b2)}
  end

  defp encode(v) when v <= 0.0031308, do: 12.92 * v
  defp encode(v), do: 1.055 * :math.pow(v, 1 / 2.4) - 0.055

  defp decode(v) when v <= 0.04045, do: v / 12.92
  defp decode(v), do: :math.pow((v + 0.055) / 1.055, 2.4)

  defp luminance({r, g, b}), do: 0.2126 * r + 0.7152 * g + 0.0722 * b

  defp contrast(one, two) do
    [dark, light] = Enum.sort([luminance(one), luminance(two)])
    (light + 0.05) / (dark + 0.05)
  end
end
