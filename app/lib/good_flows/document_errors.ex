defmodule GoodFlows.DocumentErrors do
  @moduledoc """
  Renders `{path, message}` validation errors (forward paths, as from
  `GoodFlows.TestReports.Shape.check/3`) as a map of rendered JSON paths to
  message lists, for change request, claims and review policy documents.

  An empty path renders as `root` (`body` by default, `front_matter` for
  claims). Paths only hold contract keys and indexes, and messages are
  fixed, so no submitted value is echoed. At most the first 50 errors are
  kept.
  """

  alias GoodFlows.JsonDocument

  @max_errors 50

  @typedoc "Errors keyed by rendered path."
  @type errors :: %{String.t() => [String.t()]}

  @doc "Renders `errors`, naming the document root `root`."
  @spec render([JsonDocument.error()], String.t()) :: errors()
  def render(errors, root \\ "body") when is_list(errors) do
    errors
    |> Enum.take(@max_errors)
    |> Enum.reduce(%{}, fn {path, message}, acc ->
      key = if path == [], do: root, else: JsonDocument.render_path(path)
      Map.update(acc, key, [message], &Enum.uniq(&1 ++ [message]))
    end)
  end
end
