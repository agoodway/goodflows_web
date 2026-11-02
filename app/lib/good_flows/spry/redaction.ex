defmodule GoodFlows.Spry.Redaction do
  @moduledoc """
  Scrubs Sprites tokens out of log events and Sentry events.

  The Sprites SDK keeps the account token in its own process state
  (`%Sprites.Client{token: …}`, a `token` field in command processes, and
  `authorization: Bearer …` request headers). If one of those processes
  crashes, OTP crash reports and Sentry events can include that state. The
  app cannot change the SDK, so it redacts the token on the way out:

    * `logger_filter/2` is installed as a primary `:logger` filter at
      startup, so every handler (console and `Sentry.LoggerHandler`) sees
      redacted messages, reports, and crash reasons.
    * `sentry_before_send/1` is configured as Sentry's `:before_send`
      hook for events reported by any other path.

  Redaction is structural (values under `token`/`authorization` keys and
  `%Sprites.Client{}` tokens) plus textual (already-inspected `token: "…"`,
  `"token" => "…"`, and `Bearer …` fragments). It is a mitigation, not a
  guarantee: a token formatted in some other shape is not recognized.

  A cheap `:binary.match/2` prefilter skips text (and, in `logger_filter/2`,
  whole terms via their external format) that contains none of the
  substrings every pattern and secret key requires (any letter case of
  `ken`, `zat`, or `rer`, from `token`, `authorization`, and `bearer`), so
  ordinary log events pay no regex or deep-walk cost.
  """

  @redacted "[REDACTED]"
  @secret_keys [:token, "token", :authorization, "authorization"]

  # Every case variant of a trigram that each pattern / secret key contains:
  # "ken" (token), "zat" (authorization), "rer" (bearer). A text without any
  # of them cannot match a pattern, and a term whose external format has
  # none of them has no secret key either.
  @prefilter for trigram <- ~w(ken zat rer),
                 variant <-
                   for(
                     a <- [String.at(trigram, 0), String.upcase(String.at(trigram, 0))],
                     b <- [String.at(trigram, 1), String.upcase(String.at(trigram, 1))],
                     c <- [String.at(trigram, 2), String.upcase(String.at(trigram, 2))],
                     do: a <> b <> c
                   ),
                 do: variant

  @patterns [
    {~r/(\btoken:\s*")(?:[^"\\]|\\.)*(")/, "\\1#{@redacted}\\2"},
    {~r/("(?:token|authorization)"\s*(?:=>|:)\s*")(?:[^"\\]|\\.)*(")/i, "\\1#{@redacted}\\2"},
    {~r/(\bBearer\s+)[^\s"',\]\}\)]+/i, "\\1#{@redacted}"}
  ]

  @doc """
  Returns `term` with token values replaced by `"[REDACTED]"`, walking maps,
  structs, lists, and tuples and scrubbing token-shaped text in strings.
  """
  @spec redact(term()) :: term()
  def redact(term)

  def redact(binary) when is_binary(binary) do
    if suspicious?(binary) and String.valid?(binary) do
      Enum.reduce(@patterns, binary, fn {regex, replacement}, acc ->
        Regex.replace(regex, acc, replacement)
      end)
    else
      binary
    end
  end

  def redact([head | tail]), do: [redact(head) | redact(tail)]

  def redact({key, value}) when key in @secret_keys, do: {key, secret(value)}

  def redact(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&redact/1) |> List.to_tuple()
  end

  # :maps.map/2 keeps the :__struct__ key, so structs stay structs.
  def redact(map) when is_map(map) do
    :maps.map(
      fn
        key, value when key in @secret_keys -> secret(value)
        _key, value -> redact(value)
      end,
      map
    )
  end

  def redact(other), do: other

  @doc """
  Prefilter: whether `term` could contain a token in a recognized shape.
  `false` means `redact/1` would return it unchanged.
  """
  @spec suspicious?(term()) :: boolean()
  def suspicious?(binary) when is_binary(binary),
    do: :binary.match(binary, @prefilter) != :nomatch

  def suspicious?(term), do: term |> :erlang.term_to_binary() |> suspicious?()

  defp secret(value) when is_binary(value), do: @redacted
  defp secret(values) when is_list(values), do: Enum.map(values, fn _ -> @redacted end)
  defp secret(value), do: redact(value)

  @doc """
  Primary `:logger` filter: redacts the message (string, format arguments,
  or report) and any `crash_reason` metadata. If redaction itself fails,
  the message is replaced rather than risk emitting a token.
  """
  @spec logger_filter(:logger.log_event(), term()) :: :logger.filter_return()
  def logger_filter(%{msg: msg, meta: meta} = event, _extra) do
    %{event | msg: redact_msg(msg), meta: redact_meta(meta)}
  rescue
    _error -> %{event | msg: {:string, "[log event withheld: token redaction failed]"}}
  end

  defp redact_msg({:string, chardata}), do: {:string, redact_chardata(chardata)}

  defp redact_msg({:report, report} = msg),
    do: if(suspicious?(report), do: {:report, redact(report)}, else: msg)

  defp redact_msg({format, args} = msg) when is_list(args),
    do: if(suspicious?(args), do: {format, redact(args)}, else: msg)

  defp redact_msg(other), do: other

  defp redact_chardata(chardata) when is_binary(chardata), do: redact(chardata)

  defp redact_chardata(chardata) do
    chardata |> IO.chardata_to_string() |> redact()
  end

  defp redact_meta(%{crash_reason: reason} = meta) do
    if suspicious?(reason), do: %{meta | crash_reason: redact(reason)}, else: meta
  end

  defp redact_meta(meta), do: meta

  @doc "Sentry `:before_send` hook: returns the event with tokens redacted."
  @spec sentry_before_send(struct()) :: struct()
  def sentry_before_send(event), do: redact(event)

  @doc "Installs `logger_filter/2` as a primary `:logger` filter (idempotent)."
  @spec install_logger_filter() :: :ok
  def install_logger_filter do
    case :logger.add_primary_filter(:spry_token_redaction, {&__MODULE__.logger_filter/2, []}) do
      :ok -> :ok
      {:error, {:already_exist, _id}} -> :ok
    end
  end
end
