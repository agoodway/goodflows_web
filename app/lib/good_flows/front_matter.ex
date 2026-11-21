defmodule GoodFlows.FrontMatter do
  @moduledoc """
  Extracts the YAML front matter of a Markdown file (claims files and
  scenario sets).

  `parse/1` splits the front matter (between a first `---` line and the
  next `---` line; a trailing `\r` is ignored on both, so CRLF files work)
  from the Markdown body, which is never read. YAML anchors, aliases, tags
  and `%TAG` directives, a second document and a key repeated within one
  mapping are refused from yamerl's token stream before anything is
  constructed, so an alias can never expand. yamerl's time grows faster
  than linearly with nesting and with the tokens it holds for a flow
  collection that could be an implicit key, so the front matter is fed to
  it in chunks and refused once collections nest more than 16 levels or it
  holds more than 256 tokens. A plain integer of more than 32 digits is
  refused too (yamerl builds it in quadratic time), and the front matter
  is constructed with the YAML 1.2 core schema. A front matter that is a
  JSON object is decoded as JSON instead (same result, no yamerl), with
  the same nesting and duplicate key rules. The front matter must be a
  mapping; it is returned as normalized JSON terms
  (`GoodFlows.JsonDocument.normalize/1`).

  Errors are fixed messages that never echo the input.
  """

  require Record

  alias GoodFlows.ChangeRequests.ClaimsDocument.DigitScalar
  alias GoodFlows.JsonDocument
  alias Jason.OrderedObject

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

  @doc """
  Parses the front matter of `raw` into a normalized JSON map, or returns
  a fixed error message.
  """
  @spec parse(binary()) :: {:ok, map()} | {:error, String.t()}
  def parse(raw) when is_binary(raw) do
    with {:ok, yaml} <- split(raw),
         {:ok, %{} = front_matter} <- read(yaml),
         {:ok, front_matter} <- JsonDocument.normalize(front_matter) do
      {:ok, front_matter}
    else
      {:ok, _not_a_mapping} ->
        {:error, "must be a YAML mapping"}

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, errors} ->
        if Enum.any?(errors, &match?({_path, @duplicate_key}, &1)),
          do: {:error, @duplicate_key},
          else: {:error, "must not contain NUL characters or huge integers"}
    end
  end

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
end
