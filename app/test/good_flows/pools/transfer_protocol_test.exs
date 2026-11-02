defmodule GoodFlows.Pools.TransferProtocolTest do
  use ExUnit.Case, async: true

  alias GoodFlows.Pools.TransferProtocol, as: P

  @fixtures Path.expand("../../../../sprite-transfer/tests/fixtures", __DIR__)
  @payload <<0x00, 0xFF, 0x10, 0x80, "abc">>
  @sha "584319cda5e22523b9f570ba8d262db5b82a75a48c3dd7c70914282ede4ff43d"

  # The same frames the Rust crate pins in sprite-transfer/tests/fixtures.
  @frames %{
    "open_upload.bin" =>
      {%{
         type: "open",
         transfer_id: "t-0001",
         direction: "upload",
         session_id: "s-1",
         member_id: "m-1",
         lease_generation: 3,
         artifact: "workspace.tar.gz",
         max_payload: 1_048_576,
         length: 7,
         sha256: @sha
       }, ""},
    "open_download.bin" =>
      {%{
         type: "open",
         transfer_id: "t-0002",
         direction: "download",
         session_id: "s-1",
         member_id: "m-1",
         lease_generation: 3,
         artifact: "a.jsonl",
         max_payload: 1_048_576
       }, ""},
    "ready_upload.bin" =>
      {%{
         type: "ready",
         transfer_id: "t-0001",
         committed_offset: 0,
         max_payload: 1_048_576,
         completed: false
       }, ""},
    "ready_offer.bin" =>
      {%{type: "ready", transfer_id: "t-0002", length: 7, sha256: @sha, max_payload: 1_048_576},
       ""},
    "ready_resume.bin" =>
      {%{type: "ready", transfer_id: "t-0002", committed_offset: 0, max_payload: 1_048_576}, ""},
    "chunk_binary.bin" =>
      {%{type: "chunk", transfer_id: "t-0001", offset: 0, sha256: @sha}, @payload},
    "ack.bin" => {%{type: "ack", transfer_id: "t-0001", committed_offset: 7}, ""},
    "finish.bin" => {%{type: "finish", transfer_id: "t-0001", length: 7, sha256: @sha}, ""},
    "complete.bin" =>
      {%{type: "complete", transfer_id: "t-0001", length: 7, sha256: @sha, extracted: true}, ""},
    "error.bin" => {%{type: "error", code: "bad_chunk", message: "chunk sha256 mismatch"}, ""},
    "collect.bin" =>
      {%{
         type: "collect",
         outputs_present: true,
         outputs_truncated: false,
         reports: [%{"name" => "a.jsonl", "size" => 123, "too_large" => false}],
         reports_truncated: false
       }, "ok\n"}
  }

  test "encodes byte-identical frames to the shared Rust fixtures and decodes them" do
    for {file, {header, payload}} <- @frames do
      expected = File.read!(Path.join(@fixtures, file))
      assert IO.iodata_to_binary(P.encode!(header, payload)) == expected, file

      assert {:ok, [%{header: decoded, payload: ^payload}], ""} = P.decode(expected)
      assert decoded["v"] == 1
      assert decoded["type"] == header.type
    end
  end

  test "the chunk fixture payload hashes to its header sha256" do
    assert P.sha256_hex(@payload) == @sha
  end

  test "reassembles frames split at every byte boundary, preserving binary payloads" do
    frames =
      for payload <- [<<0, 0, 0>>, :crypto.strong_rand_bytes(300), <<255, 254, 0, 128>>] do
        IO.iodata_to_binary(
          P.encode!(
            %{type: "chunk", transfer_id: "t", offset: 0, sha256: P.sha256_hex(payload)},
            payload
          )
        )
      end

    stream = IO.iodata_to_binary(frames)

    for split <- 0..byte_size(stream) do
      <<a::binary-size(split), b::binary>> = stream
      assert {:ok, first, rest} = P.decode(a)
      assert {:ok, second, ""} = P.decode(rest <> b)
      decoded = Enum.map(first ++ second, & &1.payload)

      assert decoded ==
               Enum.map(frames, fn f -> elem(P.decode(f), 1) |> hd() |> Map.get(:payload) end)
    end
  end

  test "an oversized header is refused from its prefix alone" do
    assert P.decode(<<8_193::32>>) == {:error, :header_too_large}
    assert P.decode(<<0::32>>) == {:error, :header_too_large}
    assert P.decode(<<0xFFFFFFFF::32, "x">>) == {:error, :header_too_large}
  end

  test "a payload above the negotiated maximum is refused before its bytes arrive" do
    header = ~s({"v":1,"type":"chunk","transfer_id":"t","offset":0,"sha256":"x","len":1048577})
    assert P.decode(<<byte_size(header)::32, header::binary>>) == {:error, :payload_too_large}

    small = ~s({"v":1,"type":"chunk","transfer_id":"t","offset":0,"sha256":"x","len":65537})

    assert P.decode(<<byte_size(small)::32, small::binary>>, max_payload: 65_536) ==
             {:error, :payload_too_large}
  end

  test "unknown versions and malformed headers are refused" do
    for json <- [~s({"v":2,"type":"ack"}), ~s({"v":"1","type":"ack"})] do
      assert P.decode(<<byte_size(json)::32, json::binary>>) == {:error, :unsupported_version}
    end

    for json <- [~s(not json), ~s({"type":"ack"}), ~s({"v":1,"type":"chunk","len":-1})] do
      assert P.decode(<<byte_size(json)::32, json::binary>>) == {:error, :invalid_header}
    end
  end

  test "encoding enforces the header limit, payload limit, and control frames without payloads" do
    assert P.encode(%{type: "error", code: "x", message: String.duplicate("a", 9_000)}) ==
             {:error, :header_too_large}

    assert P.encode(%{type: "chunk"}, :binary.copy(<<1>>, 11), max_payload: 10) ==
             {:error, :payload_too_large}

    assert P.encode(%{type: "ack"}, "x") == {:error, :invalid_header}
  end

  test "control frames with a payload length, a missing type, or a non-object are refused" do
    for json <- [
          ~s({"v":1,"type":"ack","transfer_id":"t","committed_offset":0,"len":3}),
          ~s({"v":1}),
          ~s({"v":1,"type":7}),
          ~s([1])
        ] do
      assert P.decode(<<byte_size(json)::32, json::binary>>) == {:error, :invalid_header}
    end

    json = ~s({"v":1,"type":"ack","transfer_id":"t","committed_offset":0,"len":0})
    assert {:ok, [_], ""} = P.decode(<<byte_size(json)::32, json::binary>>)
  end

  test "max_payload above the 1 MiB ceiling is clamped" do
    header = ~s({"v":1,"type":"chunk","transfer_id":"t","offset":0,"sha256":"x","len":1048577})

    assert P.decode(<<byte_size(header)::32, header::binary>>, max_payload: 4_000_000) ==
             {:error, :payload_too_large}

    assert P.encode(%{type: "chunk"}, :binary.copy(<<1>>, 1_048_577), max_payload: 4_000_000) ==
             {:error, :payload_too_large}
  end

  test "the incremental decoder yields frames across fragments, parsing each header once" do
    payloads = [:crypto.strong_rand_bytes(1_048_576), "", <<0, 1, 2>>]

    stream =
      payloads
      |> Enum.map(fn payload ->
        P.encode!(
          %{type: "chunk", transfer_id: "t", offset: 0, sha256: P.sha256_hex(payload)},
          payload
        )
      end)
      |> IO.iodata_to_binary()

    fragments =
      for <<piece::binary-size(65_536) <- binary_part(stream, 0, 65_536 * 16)>>, do: piece

    tail = binary_part(stream, 65_536 * 16, byte_size(stream) - 65_536 * 16)

    {frames, decoder} =
      Enum.reduce(fragments ++ [tail], {[], P.decoder()}, fn data, {acc, decoder} ->
        {:ok, frames, decoder} = P.feed(decoder, data)
        {acc ++ frames, decoder}
      end)

    assert Enum.map(frames, & &1.payload) == payloads
    assert P.buffered(decoder) == 0

    # Errors surface as soon as the header is complete.
    bad = ~s({"v":1,"type":"chunk","len":1048577})

    assert P.feed(P.decoder(), <<byte_size(bad)::32, bad::binary>>) ==
             {:error, :payload_too_large}
  end
end
