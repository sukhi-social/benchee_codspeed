defmodule Benchee.Codspeed.ProtocolTest do
  use ExUnit.Case, async: true

  alias Benchee.Codspeed.Protocol

  # Byte vectors produced by the Rust runner itself (bincode 1.x), taken from
  # instrument-hooks `src/tests/deserialize_rust/serialized.zig`. They pin the wire
  # format down byte for byte, including the enum order.
  @rust_vectors [
    {{:executed_benchmark, 12345, "http://example.com/benchmark"},
     <<0, 0, 0, 0, 57, 48, 0, 0, 28, 0, 0, 0, 0, 0, 0, 0, 104, 116, 116, 112, 58, 47, 47, 101,
       120, 97, 109, 112, 108, 101, 46, 99, 111, 109, 47, 98, 101, 110, 99, 104, 109, 97, 114,
       107>>},
    {:start_benchmark, <<1, 0, 0, 0>>},
    {:stop_benchmark, <<2, 0, 0, 0>>},
    {:ack, <<3, 0, 0, 0>>},
    {:ping_profiler, <<4, 0, 0, 0>>},
    {{:set_integration, "test-integration", "1.0.0"},
     <<5, 0, 0, 0, 16, 0, 0, 0, 0, 0, 0, 0, 116, 101, 115, 116, 45, 105, 110, 116, 101, 103, 114,
       97, 116, 105, 111, 110, 5, 0, 0, 0, 0, 0, 0, 0, 49, 46, 48, 46, 48>>},
    {:err, <<6, 0, 0, 0>>},
    {{:add_marker, 12345, {:sample_start, 1000}},
     <<7, 0, 0, 0, 57, 48, 0, 0, 0, 0, 0, 0, 232, 3, 0, 0, 0, 0, 0, 0>>},
    {{:add_marker, 12345, {:sample_end, 2000}},
     <<7, 0, 0, 0, 57, 48, 0, 0, 1, 0, 0, 0, 208, 7, 0, 0, 0, 0, 0, 0>>},
    {{:add_marker, 12345, {:benchmark_start, 3000}},
     <<7, 0, 0, 0, 57, 48, 0, 0, 2, 0, 0, 0, 184, 11, 0, 0, 0, 0, 0, 0>>},
    {{:add_marker, 12345, {:benchmark_end, 4000}},
     <<7, 0, 0, 0, 57, 48, 0, 0, 3, 0, 0, 0, 160, 15, 0, 0, 0, 0, 0, 0>>},
    {{:set_version, 1}, <<8, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0>>},
    {:get_integration_mode, <<9, 0, 0, 0>>},
    {{:integration_mode_response, :walltime}, <<10, 0, 0, 0, 0, 0, 0, 0>>},
    {{:integration_mode_response, :simulation}, <<10, 0, 0, 0, 1, 0, 0, 0>>},
    {{:integration_mode_response, :analysis}, <<10, 0, 0, 0, 2, 0, 0, 0>>}
  ]

  for {{term, bytes}, i} <- Enum.with_index(@rust_vectors) do
    @term term
    @bytes bytes

    test "vector #{i} #{inspect(@term)} encodes to the exact bytes the Rust runner produces" do
      assert Protocol.encode(@term) == @bytes
    end

    test "vector #{i} #{inspect(@term)} decodes from the bytes the Rust runner produces" do
      assert Protocol.decode(@bytes) == {:ok, @term}
    end
  end

  test "frame/1 prefixes a little-endian u32 length" do
    assert Protocol.frame(:start_benchmark) == <<4, 0, 0, 0, 1, 0, 0, 0>>

    assert Protocol.frame({:set_version, 2}) ==
             <<12, 0, 0, 0, 8, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0>>
  end

  test "unframe/1 handles partial, complete and back-to-back frames" do
    two = Protocol.frame(:ack) <> Protocol.frame(:start_benchmark)
    assert {:ok, body, rest} = Protocol.unframe(two)
    assert Protocol.decode(body) == {:ok, :ack}
    assert {:ok, body2, ""} = Protocol.unframe(rest)
    assert Protocol.decode(body2) == {:ok, :start_benchmark}

    assert Protocol.unframe("") == :incomplete
    assert Protocol.unframe(<<4, 0>>) == :incomplete
    assert Protocol.unframe(<<4, 0, 0, 0, 1, 0>>) == :incomplete
  end

  test "unframe/1 rejects absurd lengths instead of waiting for them" do
    assert {:error, {:frame_too_large, _}} = Protocol.unframe(<<255, 255, 255, 127, 0>>)
  end

  test "decode/1 rejects unknown tags, trailing bytes and bad enums" do
    assert {:error, _} = Protocol.decode(<<11, 0, 0, 0>>)
    assert {:error, _} = Protocol.decode(<<3, 0, 0, 0, 99>>)
    assert {:error, _} = Protocol.decode(<<10, 0, 0, 0, 7, 0, 0, 0>>)

    assert {:error, _} =
             Protocol.decode(<<7, 0, 0, 0, 1, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>)

    assert {:error, _} = Protocol.decode("")
  end

  test "negative pids round-trip (i32)" do
    assert Protocol.decode(Protocol.encode({:executed_benchmark, -1, "x"})) ==
             {:ok, {:executed_benchmark, -1, "x"}}
  end

  test "multi-byte UTF-8 uris use the byte length" do
    uri = "bench/ベンチ.exs::グループ::fib"

    assert Protocol.decode(Protocol.encode({:executed_benchmark, 1, uri})) ==
             {:ok, {:executed_benchmark, 1, uri}}
  end
end
