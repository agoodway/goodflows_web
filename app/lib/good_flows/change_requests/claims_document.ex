defmodule GoodFlows.ChangeRequests.ClaimsDocument do
  @moduledoc """
  Parses and validates a `change-claims/2` file (design D4).

  `parse/1` splits the YAML front matter (between a first `---` line and
  the next `---` line) from the Markdown body, which is never parsed. YAML
  anchors, aliases, tags and `%TAG` directives, a second document and a
  key repeated within one mapping are refused from yamerl's token stream
  before anything is constructed, so an alias can never expand. yamerl's
  time grows faster than linearly with nesting and with the tokens it
  holds for a flow collection that could be an implicit key, so the front
  matter is fed to it in chunks and refused once collections nest more
  than 16 levels or it holds more than 256 tokens. A plain integer of more
  than 32 digits is refused too (yamerl builds it in quadratic time), and
  the front matter is constructed with the YAML 1.2 core schema. A front
  matter that is a JSON object is decoded as JSON instead (same result, no
  yamerl), with the same nesting and duplicate key rules. The front matter
  must be a mapping.

  `validate/2` checks the ten required keys and their shapes, then the
  three server checks against stored facts: `head` equals the current
  head (which must have Git facts), every `decisions[].path` is a `path` or
  `old_path` of that head's `diff.files`, and every `safe_because[].proof`
  is a known level. `location` and `evidence` references are never
  checked. Any other `format` is a single error on `format`.

  Errors are rendered on front matter paths such as
  `safe_because[0].evidence`; the root is `front_matter`.
  """

  require Record

  alias GoodFlows.ChangeRequests.ClaimsDocument.DigitScalar
  alias GoodFlows.ChangeRequests.Params
  alias GoodFlows.DocumentErrors
  alias GoodFlows.JsonDocument
  alias GoodFlows.ReviewPolicies.Document
  alias GoodFlows.TestReports.Shape
  alias Jason.OrderedObject

  @format "change-claims/2"
  @doors ~w(one_way two_way)
  @control ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u
  @refused_tokens [:yamerl_anchor, :yamerl_alias, :yamerl_tag, :yamerl_tag_directive]
  @refused "must not use YAML anchors, aliases or tags"
  @duplicate_key "has a duplicate key"
  @max_depth 16
  @max_pending 256
  @chunk_size 512
  @too_deep "must not nest collections more than #{@max_depth} levels deep"
  @max_digits DigitScalar.max_digits()
  @too_many_digits "must not have an integer of more than #{@max_digits} digits"
  @too_long "must not have a flow collection of more than #{@max_pending} tokens that could be a key"

  # Only read, so the field defaults (some are funs) are dropped.
  Record.defrecordp(
    :yamerl_parser,
    Enum.map(
      Record.extract(:yamerl_parser, from_lib: "yamerl/include/internal/yamerl_parser.hrl"),
      fn {field, _default} -> {field, nil} end
    )
  )

  @typedoc "What the front matter is checked against."
  @type context :: %{
          number: pos_integer(),
          head: String.t() | nil,
          diff_paths: MapSet.t(String.t()) | nil
        }

  @doc "The only accepted `format`."
  @spec format() :: String.t()
  def format, do: @format

  @doc "Parses the front matter of a claims file into normalized JSON terms."
  @spec parse(binary()) :: {:ok, map()} | {:error, {:invalid_body, DocumentErrors.errors()}}
  def parse(raw) when is_binary(raw) do
    with {:ok, yaml} <- split(raw),
         {:ok, %{} = front_matter} <- read(yaml),
         {:ok, front_matter} <- JsonDocument.normalize(front_matter) do
      {:ok, front_matter}
    else
      {:ok, _not_a_mapping} ->
        invalid("must be a YAML mapping")

      {:error, message} when is_binary(message) ->
        invalid(message)

      {:error, errors} ->
        if Enum.any?(errors, &match?({_path, @duplicate_key}, &1)),
          do: invalid(@duplicate_key),
          else: invalid("must not contain NUL characters or huge integers")
    end
  end

  defp invalid(message), do: {:error, {:invalid_body, %{"front_matter" => [message]}}}

  defp split(raw) do
    case String.split(raw, "\n") do
      [first | rest] ->
        if delimiter?(first), do: front(rest, []), else: {:error, "must start with a --- line"}
    end
  end

  defp front([], _acc), do: {:error, "must end with a --- line"}

  defp front([line | rest], acc) do
    if delimiter?(line),
      do: {:ok, acc |> Enum.reverse() |> Enum.join("\n")},
      else: front(rest, [line | acc])
  end

  defp delimiter?(line), do: String.trim_trailing(line, "\r") == "---"

  # A JSON object (JSON is YAML) is decoded without yamerl: yamerl holds
  # every token of a flow collection that could be an implicit key until it
  # closes, which is quadratic for a large JSON-style front matter.
  defp read(yaml) do
    with :error <- json_object(yaml),
         :ok <- check_tokens(yaml),
         do: construct(yaml)
  end

  defp json_object(yaml) do
    with :ok <- JsonDocument.check_depth(yaml, @max_depth),
         {:ok, %OrderedObject{} = object} <- JsonDocument.decode(yaml) do
      {:ok, object}
    else
      _not_a_json_object -> :error
    end
  end

  # yamerl's time grows faster than linearly with collection nesting
  # (flow `[[[` as well as block `- - -`) and with the tokens it holds
  # pending, so the front matter is fed in small chunks and the parser's
  # own state is checked after each one, before the work can grow.
  #
  # Tokens are checked as yamerl emits them, before anything is
  # constructed: anchors, aliases and tags are refused, as are a second
  # document and a key repeated within one mapping (yamerl would keep the
  # first). The stack holds `:sequence` or `{:mapping, keys, key_next?}`.
  defp check_tokens(yaml) do
    :string
    |> :yamerl_parser.new([{:token_fun, token_fun(%{docs: 0, stack: []})}])
    |> feed(yaml)
  catch
    :throw, {__MODULE__, message} -> {:error, message}
    :throw, {:yamerl_exception, _errors} -> {:error, "is not valid YAML"}
    # yamerl crashes on some characters (a NUL or other control character
    # in a scalar) instead of throwing; the reason holds the input.
    :error, _reason -> {:error, "is not valid YAML"}
  end

  defp feed(parser, <<chunk::binary-size(@chunk_size), rest::binary>>) when rest != <<>> do
    {:continue, parser} = :yamerl_parser.next_chunk(parser, chunk)

    cond do
      length(yamerl_parser(parser, :parent_colls)) > @max_depth -> refuse(@too_deep)
      yamerl_parser(parser, :tks_queued) > @max_pending -> refuse(@too_long)
      true -> feed(parser, rest)
    end
  end

  defp feed(parser, last) do
    _parser = :yamerl_parser.last_chunk(parser, last)
    :ok
  end

  defp token_fun(state), do: &{:ok, token_fun(check_token(&1, state))}

  defp check_token(token, state) do
    case elem(token, 0) do
      name when name in @refused_tokens ->
        refuse(@refused)

      :yamerl_doc_start ->
        if state.docs > 0, do: refuse("must be a single YAML document"), else: %{state | docs: 1}

      :yamerl_collection_start ->
        %{state | stack: open_collection(token, state.stack)}

      :yamerl_collection_end ->
        %{state | stack: Enum.drop(state.stack, 1)}

      :yamerl_mapping_key ->
        %{state | stack: expect_key(state.stack)}

      :yamerl_scalar ->
        check_scalar(token)
        %{state | stack: add_key(state.stack, elem(token, 6))}

      _other ->
        state
    end
  end

  defp open_collection(_token, stack) when length(stack) >= @max_depth, do: refuse(@too_deep)

  defp open_collection(token, stack) do
    check_tag(elem(token, 3))
    frame = if elem(token, 5) == :mapping, do: {:mapping, MapSet.new(), false}, else: :sequence
    [frame | complete_key(stack)]
  end

  defp expect_key([{:mapping, keys, _key_next} | stack]), do: [{:mapping, keys, true} | stack]
  defp expect_key(stack), do: stack

  defp add_key([{:mapping, keys, true} | stack], key) do
    if MapSet.member?(keys, key),
      do: refuse(@duplicate_key),
      else: [{:mapping, MapSet.put(keys, key), false} | stack]
  end

  defp add_key(stack, _scalar), do: stack

  # A collection used as a key is not compared with other keys.
  defp complete_key([{:mapping, keys, true} | stack]), do: [{:mapping, keys, false} | stack]
  defp complete_key(stack), do: stack

  # A plain scalar that yamerl's integer resolver would read as a whole
  # costs time quadratic in its digits, so a long one is refused here;
  # valid integers have at most 16. Longer digit runs in other scalars
  # are kept from the resolver by `DigitScalar`.
  defp check_scalar(token) do
    check_tag(elem(token, 3))

    with {:yamerl_tag, _, _, {:non_specific, ~c"?"}} <- elem(token, 3),
         {:integer, digits} when digits > @max_digits <- DigitScalar.digit_run(elem(token, 6)),
         do: refuse(@too_many_digits)
  end

  # Untagged nodes carry yamerl's non-specific `?` (plain) or `!` tag.
  defp check_tag({:yamerl_tag, _line, _column, {:non_specific, _}}), do: :ok
  defp check_tag(_tag), do: refuse(@refused)

  defp refuse(message), do: throw({__MODULE__, message})

  # The core schema is used even under a `%YAML 1.1` directive, so integer
  # forms are exactly those `DigitScalar` and `check_scalar/1` know.
  defp construct(yaml) do
    case YamlElixir.read_from_string(yaml, schema: :core, node_mods: [DigitScalar]) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, "is not valid YAML"}
    end
  end

  @doc "Validates parsed front matter against `context`."
  @spec validate(map(), context()) :: :ok | {:error, {:invalid_body, DocumentErrors.errors()}}
  def validate(%{"format" => format}, _context) when format != @format,
    do: {:error, {:invalid_body, %{"format" => ["must be #{@format}"]}}}

  def validate(front_matter, context) do
    errors =
      case Shape.check(front_matter, spec(context), []) do
        [] -> server_errors(front_matter, context)
        errors -> errors
      end

    if errors == [],
      do: :ok,
      else: {:error, {:invalid_body, DocumentErrors.render(errors, "front_matter")}}
  end

  defp spec(context) do
    {:object,
     %{
       "format" => {:enum, [@format]},
       "cr" => {:fun, &cr_errors(&1, &2, context.number), :cr},
       "head" => Params.sha_spec(),
       "door" => {:enum, @doors},
       "door_reason" => nonblank(),
       "reach" => nonblank(),
       "safe_because" => {:list, safe_because_spec(), min: 1, max: 100},
       "left_open" =>
         {:list,
          {:object, %{"risk" => nonblank(), "location" => nonblank(), "affected" => nonblank()}},
          max: 100},
       "questions" =>
         {:list,
          {:object,
           %{
             "id" => nonblank(),
             "text" => nonblank(),
             "options" => {:list, nonblank()},
             "recommendation" => nonblank()
           }}, max: 50},
       "decisions" =>
         {:list,
          {:object,
           %{
             "id" => nonblank(),
             "path" => nonblank(),
             "hunk" => {:string, []},
             "note" => {:string, []}
           }}, max: 3}
     }}
  end

  defp safe_because_spec do
    {:object,
     %{
       "fact" => nonblank(),
       "location" => nonblank(),
       "proof" => {:enum, Document.proof_levels()},
       "evidence" => {:omit, {:fun, &evidence_errors/2, :evidence}},
       "covers" => {:omit, {:fun, &covers_errors/2, :covers}}
     }}
  end

  defp nonblank, do: {:string, min: 1, non_blank: true}

  defp cr_errors(nil, _path, _number), do: []
  defp cr_errors(number, _path, number), do: []

  defp cr_errors(value, path, _number) when is_integer(value),
    do: [{path, "must equal the change request's number"}]

  defp cr_errors(_value, path, _number), do: [{path, "must be an integer or null"}]

  defp evidence_errors(list, path) when is_list(list) and length(list) <= 20 do
    if Enum.all?(list, &reference?/1),
      do: [],
      else: [{path, "must hold relative references of 1 to 1024 bytes"}]
  end

  defp evidence_errors(list, path) when is_list(list),
    do: [{path, "must not have more than 20 entries"}]

  defp evidence_errors(_value, path), do: [{path, "must be an array"}]

  defp reference?(value) when is_binary(value) do
    byte_size(value) in 1..1_024 and not Regex.match?(@control, value) and
      not String.starts_with?(value, "/")
  end

  defp reference?(_value), do: false

  defp covers_errors(%{"capability" => c, "requirement" => r, "scenario" => s} = covers, path)
       when map_size(covers) == 3 do
    if Enum.all?([c, r, s], &(is_binary(&1) and String.trim(&1) != "")),
      do: [],
      else: [{path, "must have a nonempty capability, requirement and scenario"}]
  end

  defp covers_errors(_value, path),
    do: [{path, "must have exactly capability, requirement and scenario"}]

  defp server_errors(front_matter, context) do
    head_errors(front_matter["head"], context) ++
      ran_errors(front_matter["safe_because"]) ++
      unique_id_errors(front_matter["questions"], "questions") ++
      recommendation_errors(front_matter["questions"]) ++
      unique_id_errors(front_matter["decisions"], "decisions") ++
      decision_path_errors(front_matter["decisions"], context.diff_paths)
  end

  defp head_errors(_head, %{diff_paths: nil}),
    do: [{["head"], "must be a head with reported Git facts"}]

  defp head_errors(head, %{head: head}), do: []
  defp head_errors(_head, _context), do: [{["head"], "must equal the change request's head"}]

  defp ran_errors(entries) do
    indexed_errors(entries, fn entry ->
      if entry["proof"] == "ran" and Map.get(entry, "evidence", []) == [],
        do: {"evidence", "is required when proof is ran"}
    end)
    |> Enum.map(fn {index, {key, message}} -> {["safe_because", index, key], message} end)
  end

  defp recommendation_errors(questions) do
    indexed_errors(questions, fn question ->
      if question["recommendation"] not in question["options"], do: :error
    end)
    |> Enum.map(fn {index, :error} ->
      {["questions", index, "recommendation"], "must be one of the options"}
    end)
  end

  defp decision_path_errors(_decisions, nil), do: []

  defp decision_path_errors(decisions, diff_paths) do
    indexed_errors(decisions, fn decision ->
      if not MapSet.member?(diff_paths, decision["path"]), do: :error
    end)
    |> Enum.map(fn {index, :error} ->
      {["decisions", index, "path"], "must be a path in the head's diff"}
    end)
  end

  defp unique_id_errors(entries, key) do
    {errors, _seen} =
      entries
      |> Enum.with_index()
      |> Enum.reduce({[], MapSet.new()}, fn {entry, index}, {errors, seen} ->
        if MapSet.member?(seen, entry["id"]),
          do: {[{[key, index, "id"], "must be unique"} | errors], seen},
          else: {errors, MapSet.put(seen, entry["id"])}
      end)

    Enum.reverse(errors)
  end

  defp indexed_errors(entries, check) do
    for {entry, index} <- Enum.with_index(entries),
        result = check.(entry),
        result != nil,
        do: {index, result}
  end
end
