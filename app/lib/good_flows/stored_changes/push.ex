defmodule GoodFlows.StoredChanges.Push do
  @moduledoc """
  Validates a stored change push: a JSON body of exactly `files` (path to
  file text) and `source` (exactly `commit`, `branch` and `dirty`).

  Checks, in order, each answered `422` with errors keyed by what is at
  fault (`source.commit`, `files.<path>`, `files.change.md.status`):

    * the body shape: `commit` 7 to 64 lowercase hex characters or null,
      `branch` 1 to 256 bytes without control characters or null, `dirty`
      a boolean, every file a string
    * every path is `change.md`, `qa-scenarios.md`, `verification.md` or
      `specs/<capability>/spec.md` (`<capability>` one or more
      `/`-separated `[a-z0-9][a-z0-9-]*` segments), at most 512 bytes, and
      no file contains U+0000
    * at most 100 files and 2,097,152 bytes of file text
    * `change.md` is present with front matter `format`
      `goodflows-change/1`, an `id` of 1 to 64 bytes matching
      `[a-z0-9][a-z0-9-]*` and a `status` of `proposed`, `approved` or
      `archived`
    * `qa-scenarios.md`, when present, passes the scenario-set upload's
      front matter check with `source` `intent` and `change` equal to the
      id

  Nothing else of the change is checked. `size`, `door`, `capabilities`
  and `depends_on` are read from `change.md` when well formed and are nil
  otherwise.
  """

  alias GoodFlows.ChangeRequests.Params
  alias GoodFlows.DocumentErrors
  alias GoodFlows.FrontMatter
  alias GoodFlows.JsonDocument
  alias GoodFlows.ScenarioSets.Document
  alias GoodFlows.TestReports.Shape

  @segment "[a-z0-9][a-z0-9-]*"
  @slug ~r/\A[a-z0-9][a-z0-9-]*\z/
  @capability Regex.compile!("\\A#{@segment}(?:/#{@segment})*\\z")
  @spec_path Regex.compile!("\\Aspecs/#{@segment}(?:/#{@segment})*/spec\\.md\\z")
  @named_paths ~w(change.md qa-scenarios.md verification.md)
  @commit ~r/\A[0-9a-f]{7,64}\z/
  @format "goodflows-change/1"
  @statuses ~w(proposed approved archived)
  @sizes ~w(small project)
  @doors ~w(one_way two_way)
  @max_files 100
  @max_text_bytes 2_097_152
  @max_path_bytes 512
  @max_errors 50
  @nul "must not contain U+0000; remove it from the file"

  @typedoc "A validated push."
  @type t :: %{
          change_id: String.t(),
          status: String.t(),
          size: String.t() | nil,
          door: String.t() | nil,
          capabilities: [String.t()] | nil,
          depends_on: [String.t()] | nil,
          files: %{String.t() => String.t()},
          digest: binary(),
          source: %{commit: String.t() | nil, branch: String.t() | nil, dirty: boolean()}
        }

  @doc "The accepted change statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The most files a push may carry."
  @spec max_files() :: pos_integer()
  def max_files, do: @max_files

  @doc "The most UTF-8 bytes of file text a push may carry."
  @spec max_text_bytes() :: pos_integer()
  def max_text_bytes, do: @max_text_bytes

  @doc "Whether `value` is a change id: 1 to 64 bytes matching `[a-z0-9][a-z0-9-]*`."
  @spec change_id?(term()) :: boolean()
  def change_id?(value),
    do: is_binary(value) and byte_size(value) in 1..64 and Regex.match?(@slug, value)

  @doc "Validates a normalized push body."
  @spec validate(term()) :: {:ok, t()} | {:error, {:invalid_body, DocumentErrors.errors()}}
  def validate(body) do
    with :ok <- check_shape(body),
         :ok <- check_files(body["files"]),
         {:ok, fields} <- read_change(body["files"]["change.md"]),
         :ok <- check_scenarios(body["files"]["qa-scenarios.md"], fields.change_id) do
      source = body["source"]

      {:ok,
       Map.merge(fields, %{
         files: body["files"],
         digest: digest(body["files"]),
         source: %{commit: source["commit"], branch: source["branch"], dirty: source["dirty"]}
       })}
    end
  end

  @doc """
  Renders the JSON body errors of `GoodFlowsWeb.Plugs.JsonBody` for a
  push: a file holding U+0000 is named by its path, and every other error
  is on `body`.
  """
  @spec json_errors([JsonDocument.error()]) :: DocumentErrors.errors()
  def json_errors(errors) do
    errors
    |> Enum.map(fn
      {["files", path], "must not contain NUL characters"} when is_binary(path) ->
        {file_key(path), @nul}

      {_path, message} ->
        {"body", message}
    end)
    |> render()
  end

  defp check_shape(body) do
    source =
      {:object,
       %{
         "commit" => {:nullable, {:string, format: @commit}},
         "branch" => {:nullable, Params.text()},
         "dirty" => :boolean
       }}

    spec = {:object, %{"files" => {:fun, &files_shape/2, :files}, "source" => source}}

    case Shape.check(body, spec, []) do
      [] -> :ok
      errors -> invalid(DocumentErrors.render(errors))
    end
  end

  defp files_shape(files, _path) when is_map(files), do: []
  defp files_shape(_files, path), do: [{path, "must be an object from path to file text"}]

  defp check_files(files) do
    path_errors = Enum.flat_map(Enum.sort(files), &file_errors/1)

    limit_errors =
      cond do
        map_size(files) > @max_files ->
          [{"files", "must have at most #{@max_files} files; this push has #{map_size(files)}"}]

        (bytes = text_bytes(files)) > @max_text_bytes ->
          [
            {"files",
             "must hold at most #{@max_text_bytes} bytes of file text; this push has #{bytes}"}
          ]

        true ->
          []
      end

    required =
      if Map.has_key?(files, "change.md"),
        do: [],
        else: [{"files.change.md", "is required; push the change directory's change.md"}]

    case path_errors ++ limit_errors ++ required do
      [] -> :ok
      errors -> invalid(render(errors))
    end
  end

  defp text_bytes(files),
    do:
      files
      |> Map.values()
      |> Enum.reduce(0, &(&2 + if(is_binary(&1), do: byte_size(&1), else: 0)))

  defp file_errors({path, text}) do
    path_error =
      cond do
        byte_size(path) > @max_path_bytes ->
          "is longer than #{@max_path_bytes} bytes"

        path in @named_paths or Regex.match?(@spec_path, path) ->
          nil

        true ->
          "is not a file of a goodflows change; push only change.md, qa-scenarios.md, " <>
            "verification.md and specs/<capability>/spec.md"
      end

    text_error =
      cond do
        not is_binary(text) -> "must be the file's text as a string"
        :binary.match(text, <<0>>) != :nomatch -> @nul
        true -> nil
      end

    for message <- [path_error, text_error], message != nil, do: {file_key(path), message}
  end

  defp file_key(path) when byte_size(path) > @max_path_bytes,
    do: "files." <> String.slice(path, 0, 64) <> "…"

  defp file_key(path), do: "files." <> path

  defp read_change(text) do
    case FrontMatter.parse(text) do
      {:ok, front_matter} ->
        case change_errors(front_matter) do
          [] -> {:ok, fields(front_matter)}
          errors -> invalid(render(errors))
        end

      {:error, message} ->
        invalid(%{"files.change.md" => ["front matter " <> message]})
    end
  end

  defp change_errors(front_matter) do
    [
      front_matter["format"] != @format &&
        {"files.change.md.format", "must be #{@format}"},
      not change_id?(front_matter["id"]) &&
        {"files.change.md.id", "must be 1 to 64 bytes matching [a-z0-9][a-z0-9-]*"},
      front_matter["status"] not in @statuses &&
        {"files.change.md.status", "must be proposed, approved or archived"}
    ]
    |> Enum.filter(& &1)
  end

  defp fields(front_matter) do
    %{
      change_id: front_matter["id"],
      status: front_matter["status"],
      size: if(front_matter["size"] in @sizes, do: front_matter["size"]),
      door: if(front_matter["door"] in @doors, do: front_matter["door"]),
      capabilities: list_of(front_matter["capabilities"], &capability?/1),
      depends_on: list_of(front_matter["depends_on"], &change_id?/1)
    }
  end

  defp capability?(value), do: is_binary(value) and Regex.match?(@capability, value)

  defp list_of(list, valid?) when is_list(list),
    do: if(Enum.all?(list, valid?), do: list)

  defp list_of(_value, _valid?), do: nil

  defp check_scenarios(nil, _change_id), do: :ok

  defp check_scenarios(text, change_id) do
    case Document.check_content(text) do
      {:ok, front_matter} ->
        [
          front_matter["source"] != "intent" &&
            {"files.qa-scenarios.md.source", "must be intent"},
          front_matter["change"] != change_id &&
            {"files.qa-scenarios.md.change", "must equal the id in change.md"}
        ]
        |> Enum.filter(& &1)
        |> case do
          [] -> :ok
          errors -> invalid(render(errors))
        end

      {:error, message} ->
        invalid(%{"files.qa-scenarios.md" => ["front matter " <> message]})

      errors ->
        errors
        |> Enum.map(fn {["content" | rest], message} -> {scenarios_key(rest), message} end)
        |> render()
        |> invalid()
    end
  end

  defp scenarios_key([]), do: "files.qa-scenarios.md"
  defp scenarios_key(rest), do: "files.qa-scenarios.md." <> JsonDocument.render_path(rest)

  defp render(errors) do
    errors
    |> Enum.take(@max_errors)
    |> Enum.reduce(%{}, fn {key, message}, acc ->
      Map.update(acc, key, [message], &Enum.uniq(&1 ++ [message]))
    end)
  end

  defp invalid(errors), do: {:error, {:invalid_body, errors}}

  # Each path and text is length-prefixed, so no two file sets share a digest input.
  defp digest(files) do
    data =
      files
      |> Enum.sort()
      |> Enum.map(fn {path, text} ->
        [<<byte_size(path)::64>>, path, <<byte_size(text)::64>>, text]
      end)

    :crypto.hash(:sha256, data)
  end
end
