defmodule CodSpeed.Protocol do
  @moduledoc """
  Wire format of the CodSpeed runner FIFO protocol (pure functions, no I/O).

  The runner and an integration talk over two named pipes. Every message is a
  frame: a 4 byte little-endian length followed by a
  [bincode 1.x](https://docs.rs/bincode/1) encoded `Command` (little-endian,
  fixed-width integers, `u32` enum tags, `u64` string lengths).

  Commands are represented as Elixir terms. The names follow the client side
  (`instrument-hooks`); the Rust runner calls the first three
  `CurrentBenchmark`, `StartProfiler` and `StopProfiler`.

  | tag | term                                          |
  |-----|-----------------------------------------------|
  | 0   | `{:executed_benchmark, pid, uri}`             |
  | 1   | `:start_benchmark`                            |
  | 2   | `:stop_benchmark`                             |
  | 3   | `:ack`                                        |
  | 4   | `:ping_profiler`                              |
  | 5   | `{:set_integration, name, version}`           |
  | 6   | `:err`                                        |
  | 7   | `{:add_marker, pid, marker}`                  |
  | 8   | `{:set_version, protocol_version}`            |
  | 9   | `:get_integration_mode`                       |
  | 10  | `{:integration_mode_response, mode}`          |

  Markers are `{:sample_start | :sample_end | :benchmark_start | :benchmark_end, timestamp_ns}`
  (the Rust runner calls the last two `RoundStart` and `RoundEnd`; same wire tags)
  and modes are `:walltime | :simulation | :analysis`.

  The enum order is part of the protocol: it must never be reordered.
  """

  @protocol_version 2

  @type marker ::
          {:sample_start | :sample_end | :benchmark_start | :benchmark_end, non_neg_integer()}
  @type mode :: :walltime | :simulation | :analysis
  @type command ::
          {:executed_benchmark, integer(), String.t()}
          | :start_benchmark
          | :stop_benchmark
          | :ack
          | :ping_profiler
          | {:set_integration, String.t(), String.t()}
          | :err
          | {:add_marker, integer(), marker()}
          | {:set_version, non_neg_integer()}
          | :get_integration_mode
          | {:integration_mode_response, mode()}

  # Frames bigger than this are treated as a corrupted stream.
  @max_frame_size 1_048_576

  @doc "Protocol version spoken by this client (`CURRENT_PROTOCOL_VERSION` of the runner)."
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @doc "Encodes a command to its bincode body (without the length prefix)."
  @spec encode(command()) :: binary()
  def encode({:executed_benchmark, pid, uri}) when is_integer(pid) and is_binary(uri),
    do: <<0::32-little, pid::32-little-signed, string(uri)::binary>>

  def encode(:start_benchmark), do: <<1::32-little>>
  def encode(:stop_benchmark), do: <<2::32-little>>
  def encode(:ack), do: <<3::32-little>>
  def encode(:ping_profiler), do: <<4::32-little>>

  def encode({:set_integration, name, version}) when is_binary(name) and is_binary(version),
    do: <<5::32-little, string(name)::binary, string(version)::binary>>

  def encode(:err), do: <<6::32-little>>

  def encode({:add_marker, pid, marker}) when is_integer(pid),
    do: <<7::32-little, pid::32-little-signed, encode_marker(marker)::binary>>

  def encode({:set_version, version}) when is_integer(version) and version >= 0,
    do: <<8::32-little, version::64-little>>

  def encode(:get_integration_mode), do: <<9::32-little>>

  def encode({:integration_mode_response, mode}),
    do: <<10::32-little, mode_tag(mode)::32-little>>

  @doc "Encodes a command as a complete frame (length prefix + body)."
  @spec frame(command()) :: binary()
  def frame(command) do
    body = encode(command)
    <<byte_size(body)::32-little, body::binary>>
  end

  @doc """
  Decodes a bincode body (without the length prefix).

  The whole binary must be consumed, trailing bytes are an error.
  """
  @spec decode(binary()) :: {:ok, command()} | {:error, term()}
  def decode(<<0::32-little, pid::32-little-signed, len::64-little, uri::binary-size(len)>>),
    do: {:ok, {:executed_benchmark, pid, uri}}

  def decode(<<1::32-little>>), do: {:ok, :start_benchmark}
  def decode(<<2::32-little>>), do: {:ok, :stop_benchmark}
  def decode(<<3::32-little>>), do: {:ok, :ack}
  def decode(<<4::32-little>>), do: {:ok, :ping_profiler}

  def decode(
        <<5::32-little, nlen::64-little, name::binary-size(nlen), vlen::64-little,
          version::binary-size(vlen)>>
      ),
      do: {:ok, {:set_integration, name, version}}

  def decode(<<6::32-little>>), do: {:ok, :err}

  def decode(<<7::32-little, pid::32-little-signed, marker::binary>>) do
    with {:ok, marker} <- decode_marker(marker), do: {:ok, {:add_marker, pid, marker}}
  end

  def decode(<<8::32-little, version::64-little>>), do: {:ok, {:set_version, version}}
  def decode(<<9::32-little>>), do: {:ok, :get_integration_mode}

  def decode(<<10::32-little, mode::32-little>>) do
    with {:ok, mode} <- decode_mode(mode), do: {:ok, {:integration_mode_response, mode}}
  end

  def decode(binary) when is_binary(binary), do: {:error, {:invalid_command, binary}}

  @doc """
  Splits the first complete frame off a buffer.

  Returns `:incomplete` while more bytes are needed.
  """
  @spec unframe(binary()) ::
          {:ok, body :: binary(), rest :: binary()} | :incomplete | {:error, term()}
  def unframe(<<len::32-little, _::binary>>) when len > @max_frame_size,
    do: {:error, {:frame_too_large, len}}

  def unframe(<<len::32-little, body::binary-size(len), rest::binary>>), do: {:ok, body, rest}
  def unframe(buffer) when is_binary(buffer), do: :incomplete

  @doc "Maximum accepted frame size in bytes."
  def max_frame_size, do: @max_frame_size

  # -- helpers ----------------------------------------------------------------

  defp string(s), do: <<byte_size(s)::64-little, s::binary>>

  defp encode_marker({:sample_start, ts}) when is_integer(ts) and ts >= 0,
    do: <<0::32-little, ts::64-little>>

  defp encode_marker({:sample_end, ts}) when is_integer(ts) and ts >= 0,
    do: <<1::32-little, ts::64-little>>

  defp encode_marker({:benchmark_start, ts}) when is_integer(ts) and ts >= 0,
    do: <<2::32-little, ts::64-little>>

  defp encode_marker({:benchmark_end, ts}) when is_integer(ts) and ts >= 0,
    do: <<3::32-little, ts::64-little>>

  defp decode_marker(<<0::32-little, ts::64-little>>), do: {:ok, {:sample_start, ts}}
  defp decode_marker(<<1::32-little, ts::64-little>>), do: {:ok, {:sample_end, ts}}
  defp decode_marker(<<2::32-little, ts::64-little>>), do: {:ok, {:benchmark_start, ts}}
  defp decode_marker(<<3::32-little, ts::64-little>>), do: {:ok, {:benchmark_end, ts}}
  defp decode_marker(other), do: {:error, {:invalid_marker, other}}

  defp mode_tag(:walltime), do: 0
  defp mode_tag(:simulation), do: 1
  defp mode_tag(:analysis), do: 2

  defp decode_mode(0), do: {:ok, :walltime}
  defp decode_mode(1), do: {:ok, :simulation}
  defp decode_mode(2), do: {:ok, :analysis}
  defp decode_mode(other), do: {:error, {:invalid_mode, other}}
end
