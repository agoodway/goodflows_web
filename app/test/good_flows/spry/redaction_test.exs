defmodule GoodFlows.Spry.RedactionTest do
  use ExUnit.Case, async: true

  alias GoodFlows.Spry.Redaction

  @token "sprites_live_supersecret_9f8e"

  test "redacts the token in an SDK client struct and nested process state" do
    client = Sprites.new(@token, base_url: "http://127.0.0.1:9")
    state = %{token: @token, sprite: %{client: client}, opts: [token: @token], url: "wss://x"}

    redacted = Redaction.redact(state)
    refute inspect(redacted, limit: :infinity, printable_limit: :infinity) =~ @token
    assert %Sprites.Client{token: "[REDACTED]"} = redacted.sprite.client
    assert redacted.url == "wss://x"
  end

  test "redacts token-shaped text in strings" do
    for text <- [
          ~s(%Sprites.Client{token: "#{@token}", base_url: "x"}),
          ~s(%{"token" => "#{@token}"}),
          ~s({"authorization", "Bearer #{@token}"}),
          "authorization: Bearer #{@token}"
        ] do
      refute Redaction.redact(text) =~ @token
    end

    assert Redaction.redact("nothing secret here") == "nothing secret here"
  end

  test "the logger filter redacts reports, format args, strings, and crash reasons" do
    meta = %{crash_reason: {%RuntimeError{message: "Bearer #{@token}"}, []}}

    for msg <- [
          {:report, %{label: {:gen_server, :terminate}, state: %{token: @token}}},
          {~c"** State: ~p", [%{token: @token}]},
          {:string, ["state: ", ~s(token: "#{@token}")]}
        ] do
      event = %{level: :error, msg: msg, meta: meta}
      redacted = Redaction.logger_filter(event, [])
      refute inspect(redacted, limit: :infinity, printable_limit: :infinity) =~ @token
    end
  end

  test "the Sentry hook redacts events" do
    event = %Sentry.Event{
      event_id: "x",
      timestamp: "now",
      message: %Sentry.Interfaces.Message{formatted: ~s(state: %{token: "#{@token}"})},
      extra: %{genserver_state: ~s(%{token: "#{@token}"}), client: %{token: @token}}
    }

    redacted = Redaction.sentry_before_send(event)
    assert %Sentry.Event{} = redacted
    refute inspect(redacted, limit: :infinity, printable_limit: :infinity) =~ @token
  end

  test "the filter is installed at startup and applied to logged crash state" do
    assert Enum.any?(:logger.get_primary_config().filters, fn {id, _} ->
             id == :spry_token_redaction
           end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :logger.error(~c"crash state: ~p", [%{token: @token}])
      end)

    assert log =~ "[REDACTED]"
    refute log =~ @token
  end

  describe "prefilter" do
    test "text and terms without any token-shaped substring are returned as is" do
      text = "an ordinary log line about sprite app-feat-x"
      refute Redaction.suspicious?(text)
      assert Redaction.redact(text) == text

      term = %{step: 1, sprite: "app-feat-x", list: [1, 2, {:ok, "fine"}]}
      refute Redaction.suspicious?(term)

      event = %{level: :info, msg: {:report, term}, meta: %{}}
      assert Redaction.logger_filter(event, []) == event
    end

    test "every case of the recognized shapes still passes the prefilter" do
      for text <- [
            ~s(token: "#{@token}"),
            ~s("AUTHORIZATION" => "#{@token}"),
            "BeArEr #{@token}",
            ~s("Token": "#{@token}")
          ] do
        assert Redaction.suspicious?(text), text
        refute Redaction.redact(text) =~ @token
      end

      assert Redaction.suspicious?(%{token: "x"})
      assert Redaction.suspicious?(Sprites.new(@token, base_url: "http://127.0.0.1:9"))
      assert Redaction.suspicious?([{"authorization", "x"}])
    end
  end

  test "the logger filter fails closed when redaction raises" do
    event = %{level: :error, msg: {:string, [:not_chardata]}, meta: %{}}

    assert %{msg: {:string, "[log event withheld: token redaction failed]"}} =
             Redaction.logger_filter(event, [])
  end
end
