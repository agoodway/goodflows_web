defmodule GoodFlows.Caches.ObjectStore.S3XML do
  @moduledoc false
  # Reads the S3 XML responses `GoodFlows.Caches.ObjectStore.S3` needs
  # (InitiateMultipartUploadResult, ListPartsResult,
  # CompleteMultipartUploadResult, Error) with `:xmerl_sax_parser`, entity
  # declarations disallowed. `req_s3`'s parser is private to it.

  @typedoc "An element: local name, child elements, concatenated text."
  @type element :: {String.t(), [element()], String.t()}

  # Error codes that S3 returns, also inside a `200` body, for a request
  # worth retrying rather than a refusal of the request.
  @retryable_codes ~w(InternalError SlowDown ServiceUnavailable RequestTimeout)

  @doc "Parses `xml` into its root element."
  @spec parse(binary()) :: {:ok, element()} | :error
  def parse(xml) when is_binary(xml) do
    options = [
      :disallow_entities,
      external_entities: :none,
      event_fun: &event/3,
      event_state: [{"", [], []}]
    ]

    case :xmerl_sax_parser.stream(xml, options) do
      {:ok, [{"", [root], _text}], _rest} -> {:ok, root}
      _other -> :error
    end
  catch
    _kind, _reason -> :error
  end

  def parse(_xml), do: :error

  @doc "The `UploadId` of an InitiateMultipartUploadResult."
  @spec upload_id(binary()) :: {:ok, String.t()} | :error
  def upload_id(xml) do
    with {:ok, {"InitiateMultipartUploadResult", _, _} = root} <- parse(xml),
         id when id not in [nil, ""] <- text(root, "UploadId") do
      {:ok, id}
    else
      _other -> :error
    end
  end

  @doc """
  The parts of one ListPartsResult page (ETags without quotes, lower-cased)
  and the next page's marker, `nil` on the last page.
  """
  @spec list_parts(binary()) ::
          {:ok, [GoodFlows.Caches.ObjectStore.part()], non_neg_integer() | nil} | :error
  def list_parts(xml) do
    with {:ok, {"ListPartsResult", children, _} = root} <- parse(xml),
         {:ok, parts} <- parts(children),
         {:ok, next} <- next_marker(root) do
      {:ok, parts, next}
    else
      _other -> :error
    end
  end

  @doc """
  The outcome of a CompleteMultipartUpload `200` body: `:ok`, or the error
  S3 put into the body (`{:rejected, code}` for a refusal, `{:store_error,
  code}` for one worth retrying).
  """
  @spec complete_result(binary()) ::
          :ok | {:error, {:rejected, String.t()} | {:store_error, String.t()}} | :error
  def complete_result(xml) do
    case parse(xml) do
      {:ok, {"CompleteMultipartUploadResult", _, _}} -> :ok
      {:ok, {"Error", _, _} = root} -> {:error, classify(text(root, "Code"))}
      _other -> :error
    end
  end

  @doc "The `Code` of an Error body, or `nil`."
  @spec error_code(binary()) :: String.t() | nil
  def error_code(xml) do
    case parse(xml) do
      {:ok, {"Error", _, _} = root} -> text(root, "Code")
      _other -> nil
    end
  end

  @doc "Whether an S3 error code asks for a retry."
  @spec retryable?(String.t() | nil) :: boolean()
  def retryable?(code), do: code in @retryable_codes

  @doc """
  Classifies an S3 error code: `{:store_error, code}` for one worth
  retrying (or none at all), otherwise `{:rejected, code}`.
  """
  @spec classify(String.t() | nil) :: {:rejected, String.t()} | {:store_error, String.t()}
  def classify(code) when code in [nil, ""], do: {:store_error, "unknown"}

  def classify(code),
    do: if(retryable?(code), do: {:store_error, code}, else: {:rejected, code})

  defp parts(children) do
    children
    |> Enum.filter(&match?({"Part", _, _}, &1))
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      with {number, ""} <- integer(text(part, "PartNumber")),
           {size, ""} <- integer(text(part, "Size")),
           etag when etag not in [nil, ""] <- text(part, "ETag") do
        etag = etag |> String.trim() |> String.trim("\"") |> String.downcase()
        {:cont, {:ok, [%{number: number, etag: etag, size: size} | acc]}}
      else
        _other -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      :error -> :error
    end
  end

  defp next_marker(root) do
    case text(root, "IsTruncated") do
      "true" ->
        case integer(text(root, "NextPartNumberMarker")) do
          {marker, ""} -> {:ok, marker}
          _other -> :error
        end

      _not_truncated ->
        {:ok, nil}
    end
  end

  defp integer(nil), do: :error
  defp integer(value), do: value |> String.trim() |> Integer.parse()

  defp text({_name, children, _text}, name) do
    Enum.find_value(children, fn
      {^name, _children, text} -> text
      _other -> nil
    end)
  end

  defp event({:startElement, _uri, name, _qualified, _attributes}, _location, stack),
    do: [{List.to_string(name), [], []} | stack]

  defp event({:endElement, _uri, _name, _qualified}, _location, [current, parent | stack]) do
    {name, children, text} = current
    {parent_name, parent_children, parent_text} = parent
    element = {name, Enum.reverse(children), IO.iodata_to_binary(text)}
    [{parent_name, [element | parent_children], parent_text} | stack]
  end

  defp event({:characters, chars}, _location, [{name, children, text} | stack]),
    do: [{name, children, [text, List.to_string(chars)]} | stack]

  defp event(_event, _location, stack), do: stack
end
