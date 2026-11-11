defmodule Benchee.Codspeed.Runner do
  @moduledoc """
  Client for the CodSpeed runner's FIFO protocol (walltime mode).

  While a benchmark runs under `codspeed run -m walltime`, the runner records
  CPU samples with `perf`, but keeps `perf` **paused** until the benchmarked
  process asks it to sample. This module is that conversation:

      Benchee.Codspeed.Runner.connect(integration: {"codspeed-elixir", "0.1.0"})

      Benchee.Codspeed.Runner.start_benchmark()        # perf on
      run_the_benchmark()
      Benchee.Codspeed.Runner.stop_benchmark()         # perf off
      Benchee.Codspeed.Runner.set_executed_benchmark("bench/x.exs::Group::name")

  Windows and URIs are matched up in order by the runner, so every
  `start_benchmark/0` ... `stop_benchmark/0` pair must be followed by exactly one
  `set_executed_benchmark/1`, and the URI must be the one written to the
  walltime results file (see `Benchee.Codspeed.benchmark_uri/4`).

  ## Behaviour

  It mirrors the official client (`instrument-hooks`):

    * Both FIFOs are opened read/write, so opening never blocks. If a FIFO does
      not exist there is no runner and every call is a no-op returning `:ok`.
    * The handshake sends `SetVersion` and asks for the integration mode; only
      `:walltime` is accepted.
    * Every command is acknowledged by the runner and this client waits for that
      ack (default 1s). The runner relies on this: it drops unread commands when
      the benchmarked process exits.
    * When the runner stops answering, the connection is closed and all further
      calls become no-ops, so a misbehaving runner can never wedge a benchmark.

  Unlike the official clients, a failed handshake does not abort the process:
  the results file is still useful without profiling, so `connect/1` returns
  `{:disabled, reason}` and a warning is printed.

  The connection is only attempted when `CODSPEED_ENV` is set (the runner sets it
  for the benchmarked process), so local runs never touch stale FIFOs.

  ## Options for `connect/1`

    * `:integration` - `{name, version}` announced with `SetIntegration`.
    * `:timeout` - ack timeout in ms (default `1000`).
    * `:force` - skip the `CODSPEED_ENV` check (used in tests).
    * `:ctl_fifo` / `:ack_fifo` - FIFO paths (default `/tmp/runner.ctl.fifo` and
      `/tmp/runner.ack.fifo`).
  """

  use GenServer

  alias Benchee.Codspeed.Protocol

  @default_ctl "/tmp/runner.ctl.fifo"
  @default_ack "/tmp/runner.ack.fifo"
  @default_timeout 1_000

  # -- public API --------------------------------------------------------------

  @doc """
  Connects to the runner. Returns `:ok` when profiling is available (or already
  connected) and `{:disabled, reason}` when it is not.
  """
  @spec connect(keyword()) :: :ok | {:disabled, term()}
  def connect(opts \\ []) do
    if Process.whereis(__MODULE__) do
      :ok
    else
      case GenServer.start(__MODULE__, opts, name: __MODULE__) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, {:shutdown, {:disabled, reason}}} -> {:disabled, reason}
        {:error, other} -> {:disabled, other}
      end
    end
  end

  @doc "True while a runner connection is open."
  @spec connected?() :: boolean()
  def connected?, do: Process.whereis(__MODULE__) != nil

  @doc "Closes the connection."
  @spec disconnect() :: :ok
  def disconnect do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  catch
    :exit, _ -> :ok
  end

  @doc "Resumes profiling (`StartProfiler`)."
  @spec start_benchmark() :: :ok | {:error, term()}
  def start_benchmark, do: command(:start_benchmark)

  @doc "Pauses profiling (`StopProfiler`)."
  @spec stop_benchmark() :: :ok | {:error, term()}
  def stop_benchmark, do: command(:stop_benchmark)

  @doc """
  Reports which benchmark just ran (`CurrentBenchmark`). Call it after
  `stop_benchmark/0`. `pid` is the OS pid of the benchmarked process.
  """
  @spec set_executed_benchmark(String.t(), integer()) :: :ok | {:error, term()}
  def set_executed_benchmark(uri, pid \\ os_pid()), do: command({:executed_benchmark, pid, uri})

  @doc "Announces the integration name and version (`SetIntegration`)."
  @spec set_integration(String.t(), String.t()) :: :ok | {:error, term()}
  def set_integration(name, version), do: command({:set_integration, name, version})

  @doc """
  Adds a marker. Timestamps must come from `current_timestamp/0`.

  Markers narrow the sampled region down (for example to the timed part of a
  round); without them the runner uses the whole `start_benchmark/0` ...
  `stop_benchmark/0` window.
  """
  @spec add_marker(Protocol.marker(), integer()) :: :ok | {:error, term()}
  def add_marker(marker, pid \\ os_pid()), do: command({:add_marker, pid, marker})

  @doc """
  `CLOCK_MONOTONIC` in nanoseconds, the clock the runner and `perf` use.

  The BEAM's own monotonic time has an arbitrary offset, so this calibrates it
  once against `:erlang.system_info(:os_monotonic_time_source)`.
  """
  @spec current_timestamp() :: non_neg_integer()
  def current_timestamp, do: :erlang.monotonic_time(:nanosecond) + monotonic_offset()

  @doc false
  def os_pid, do: :os.getpid() |> List.to_integer()

  # -- clock ---------------------------------------------------------------------

  defp monotonic_offset do
    key = {__MODULE__, :monotonic_offset}

    case :persistent_term.get(key, nil) do
      nil ->
        offset = calibrate_clock()
        :persistent_term.put(key, offset)
        offset

      offset ->
        offset
    end
  end

  # Take the sample where the two BEAM readings around the OS reading are closest.
  defp calibrate_clock do
    1..21
    |> Enum.map(fn _ ->
      before_ns = :erlang.monotonic_time(:nanosecond)
      os_ns = os_monotonic_ns()
      after_ns = :erlang.monotonic_time(:nanosecond)
      {after_ns - before_ns, os_ns - div(before_ns + after_ns, 2)}
    end)
    |> Enum.min_by(&elem(&1, 0))
    |> elem(1)
  end

  defp os_monotonic_ns do
    info = :erlang.system_info(:os_monotonic_time_source)

    unless Keyword.get(info, :clock_id) == :CLOCK_MONOTONIC do
      raise "Benchee.Codspeed.Runner needs the BEAM to use CLOCK_MONOTONIC, got: #{inspect(info)}"
    end

    # `time` is expressed in 1/resolution seconds.
    div(Keyword.fetch!(info, :time) * 1_000_000_000, Keyword.fetch!(info, :resolution))
  end

  # -- calling the server --------------------------------------------------------

  defp command(cmd) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, {:command, cmd}, :infinity)
    end
  catch
    # The server stops itself when the runner goes silent.
    :exit, _ -> {:error, :runner_gone}
  end

  # -- GenServer -------------------------------------------------------------------

  @impl true
  def init(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    ctl_path = Keyword.get(opts, :ctl_fifo, @default_ctl)
    ack_path = Keyword.get(opts, :ack_fifo, @default_ack)

    with :ok <- check_env(opts),
         :ok <- check_fifo(ctl_path),
         :ok <- check_fifo(ack_path),
         {:ok, ctl} <- open_fifo(ctl_path),
         {:ok, reader} <- start_reader(ack_path) do
      state = %{ctl: ctl, reader: reader, ack_path: ack_path, timeout: timeout}

      case handshake(state, Keyword.get(opts, :integration)) do
        :ok ->
          {:ok, state}

        {:error, reason} ->
          close(state)
          warn("profiling disabled: #{format_reason(reason)}")
          {:stop, {:shutdown, {:disabled, reason}}}
      end
    else
      {:error, reason} -> {:stop, {:shutdown, {:disabled, reason}}}
    end
  end

  @impl true
  def handle_call({:command, cmd}, _from, state) do
    case request(state, cmd) do
      {:ok, :ack} ->
        {:reply, :ok, state}

      {:ok, :err} ->
        {:reply, {:error, :runner_error}, state}

      {:ok, other} ->
        {:reply, {:error, {:unexpected_reply, other}}, state}

      {:error, reason} ->
        # The ack stream can no longer be trusted (a late ack would be read as
        # the answer to the next command), so stop talking to the runner.
        warn("lost the runner (#{format_reason(reason)}); profiling disabled")
        {:stop, :normal, {:error, reason}, state}
    end
  end

  @impl true
  def terminate(_reason, state), do: close(state)

  # -- handshake -------------------------------------------------------------------

  defp handshake(state, integration) do
    with {:ok, :ack} <- request(state, {:set_version, Protocol.protocol_version()}),
         {:ok, {:integration_mode_response, :walltime}} <-
           request(state, :get_integration_mode),
         :ok <- announce(state, integration) do
      :ok
    else
      {:ok, :err} -> {:error, :protocol_version_rejected}
      {:ok, {:integration_mode_response, mode}} -> {:error, {:unsupported_mode, mode}}
      {:ok, other} -> {:error, {:unexpected_reply, other}}
      {:error, :ack_timeout} -> {:error, :no_runner}
      {:error, _} = error -> error
    end
  end

  defp announce(_state, nil), do: :ok

  defp announce(state, {name, version}) do
    case request(state, {:set_integration, name, version}) do
      {:ok, :ack} -> :ok
      {:ok, other} -> {:error, {:unexpected_reply, other}}
      {:error, _} = error -> error
    end
  end

  # -- request / response ----------------------------------------------------------

  defp request(%{ctl: ctl, timeout: timeout}, cmd) do
    with :ok <- :file.write(ctl, Protocol.frame(cmd)) do
      receive do
        {:codspeed_frame, body} -> Protocol.decode(body)
        {:codspeed_ack_closed, reason} -> {:error, {:ack_closed, reason}}
      after
        timeout -> {:error, :ack_timeout}
      end
    end
  end

  # -- FIFOs -----------------------------------------------------------------------

  defp check_env(opts) do
    if Keyword.get(opts, :force, false) or System.get_env("CODSPEED_ENV") not in [nil, ""] do
      :ok
    else
      {:error, :not_running_under_codspeed}
    end
  end

  # A regular file or a missing path means there is no runner. Opening with
  # `:read` + `:write` would otherwise create a regular file here.
  defp check_fifo(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :other}} -> :ok
      {:ok, _} -> {:error, {:not_a_fifo, path}}
      {:error, :enoent} -> {:error, :no_runner}
      {:error, reason} -> {:error, {:fifo_unavailable, path, reason}}
    end
  end

  # Read/write on a FIFO never blocks on open (Linux), like the official client.
  defp open_fifo(path), do: :file.open(path, [:read, :write, :raw, :binary])

  # Raw files can only be used by the process that opened them, so a dedicated
  # process owns the ack FIFO and forwards complete frames. Blocking reads live
  # there, which lets `request/2` use a plain `receive ... after` timeout.
  defp start_reader(path) do
    parent = self()
    ref = make_ref()

    pid =
      spawn_link(fn ->
        case open_fifo(path) do
          {:ok, fd} ->
            send(parent, {ref, :opened})
            read_loop(fd, parent)

          {:error, reason} ->
            send(parent, {ref, {:error, {:cannot_open, path, reason}}})
        end
      end)

    receive do
      {^ref, :opened} -> {:ok, pid}
      {^ref, {:error, _} = error} -> error
    after
      2_000 -> {:error, :reader_open_timeout}
    end
  end

  defp read_loop(fd, parent) do
    with {:ok, <<len::32-little>>} <- read_exact(fd, 4),
         true <- len <= Protocol.max_frame_size() or {:error, {:frame_too_large, len}},
         {:ok, body} <- read_exact(fd, len) do
      send(parent, {:codspeed_frame, body})
      read_loop(fd, parent)
    else
      other -> send(parent, {:codspeed_ack_closed, other})
    end
  end

  # Never ask for more bytes than the frame needs: a FIFO read may return fewer.
  defp read_exact(_fd, 0), do: {:ok, ""}
  defp read_exact(fd, n), do: read_exact(fd, n, [])

  defp read_exact(_fd, 0, acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp read_exact(fd, n, acc) do
    case :file.read(fd, n) do
      {:ok, data} -> read_exact(fd, n - byte_size(data), [data | acc])
      other -> other
    end
  end

  # The reader is blocked in a `read` on a dirty IO thread. Killing the process
  # would leave that read pending at the OS level, where it would silently eat
  # the acks of the next connection. Instead wake it with an impossible frame
  # length so it exits by itself and closes the FIFO, and wait for that.
  defp close(%{ctl: ctl, reader: reader, ack_path: ack_path}) do
    :file.close(ctl)
    Process.unlink(reader)
    ref = Process.monitor(reader)

    with :ok <- check_fifo(ack_path),
         {:ok, fd} <- open_fifo(ack_path) do
      :file.write(fd, <<0xFFFFFFFF::32>>)
      :file.close(fd)
    end

    receive do
      {:DOWN, ^ref, :process, ^reader, _} -> :ok
    after
      1_000 ->
        Process.exit(reader, :kill)
        :ok
    end
  end

  # -- messages --------------------------------------------------------------------

  defp format_reason(:no_runner), do: "no answer from the runner"
  defp format_reason(:ack_timeout), do: "the runner did not acknowledge a command in time"

  defp format_reason(:protocol_version_rejected),
    do:
      "the runner rejected protocol version #{Protocol.protocol_version()}; update the CodSpeed runner/action"

  defp format_reason({:unsupported_mode, mode}),
    do: "the runner is in #{inspect(mode)} mode, only walltime is supported"

  defp format_reason(other), do: inspect(other)

  defp warn(message), do: IO.puts(:stderr, "[codspeed] #{message}")
end
