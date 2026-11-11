defmodule Benchee.Codspeed.Test.FakeRunner do
  @moduledoc false
  # A minimal stand-in for the CodSpeed runner's FIFO server. Every decoded
  # command is forwarded to the test process as `{:fake_cmd, command, ts}`, where
  # `ts` is the CLOCK_MONOTONIC receive time (like the runner takes).

  alias Benchee.Codspeed.Protocol

  def start(opts \\ []) do
    id = System.unique_integer([:positive])
    ctl = Path.join(System.tmp_dir!(), "codspeed_test_#{id}.ctl")
    ack = ctl <> ".ack"
    {_, 0} = System.cmd("mkfifo", [ctl, ack])

    parent = self()
    pid = spawn_link(fn -> serve(ctl, ack, parent, opts) end)

    receive do
      {:fake_ready, ^pid} -> %{pid: pid, ctl: ctl, ack: ack}
    after
      2_000 -> raise "fake runner did not start"
    end
  end

  # Wakes the server up with an impossible frame length (it is blocked in read/2).
  def stop(%{pid: pid, ctl: ctl, ack: ack}) do
    ref = Process.monitor(pid)
    {:ok, fd} = :file.open(ctl, [:read, :write, :raw, :binary])
    :file.write(fd, <<0xFFFFFFFF::32>>)
    :file.close(fd)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      1_000 -> Process.exit(pid, :kill)
    end

    File.rm(ctl)
    File.rm(ack)
  end

  def flush(acc \\ []) do
    receive do
      {:fake_cmd, cmd, ts} -> flush([{cmd, ts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp serve(ctl, ack, parent, opts) do
    {:ok, c} = :file.open(ctl, [:read, :write, :raw, :binary])
    {:ok, a} = :file.open(ack, [:read, :write, :raw, :binary])
    send(parent, {:fake_ready, self()})
    loop(c, a, parent, opts, 0)
  end

  defp loop(c, a, parent, opts, handled) do
    with {:ok, <<len::32-little>>} <- read_exact(c, 4),
         true <- len < 1_000_000,
         {:ok, body} <- read_exact(c, len),
         {:ok, cmd} <- Protocol.decode(body) do
      send(parent, {:fake_cmd, cmd, Benchee.Codspeed.Runner.current_timestamp()})
      handled = handled + 1

      silent_after = Keyword.get(opts, :silent_after)

      if silent_after == nil or handled <= silent_after do
        :file.write(a, Protocol.frame(reply(cmd, opts)))
      end

      loop(c, a, parent, opts, handled)
    else
      _ -> :ok
    end
  end

  defp reply({:set_version, _}, _opts), do: :ack

  defp reply(:get_integration_mode, opts),
    do: {:integration_mode_response, Keyword.get(opts, :mode, :walltime)}

  defp reply(_other, _opts), do: :ack

  defp read_exact(_fd, 0), do: {:ok, ""}
  defp read_exact(fd, n), do: read_exact(fd, n, [])
  defp read_exact(_fd, 0, acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp read_exact(fd, n, acc) do
    case :file.read(fd, n) do
      {:ok, data} -> read_exact(fd, n - byte_size(data), [data | acc])
      other -> other
    end
  end
end

defmodule Benchee.Codspeed.RunnerTest do
  use ExUnit.Case, async: false

  alias Benchee.Codspeed.Runner
  alias Benchee.Codspeed.Test.FakeRunner

  setup do
    on_exit(fn -> Runner.disconnect() end)
    :ok
  end

  defp connect(fake, extra \\ []) do
    Runner.connect([force: true, ctl_fifo: fake.ctl, ack_fifo: fake.ack] ++ extra)
  end

  defp with_fake(opts \\ [], fun) do
    fake = FakeRunner.start(opts)

    try do
      fun.(fake)
    after
      Runner.disconnect()
      FakeRunner.stop(fake)
    end
  end

  @tag :clock_monotonic
  test "handshake, then commands in order, each one acknowledged" do
    with_fake(fn fake ->
      assert connect(fake, integration: {"codspeed-elixir", "0.1.0"}) == :ok
      assert Runner.connected?()

      pid = Runner.os_pid()
      assert Runner.start_benchmark() == :ok
      assert Runner.add_marker({:sample_start, Runner.current_timestamp()}) == :ok
      assert Runner.stop_benchmark() == :ok
      assert Runner.set_executed_benchmark("bench/x.exs::G::fib") == :ok

      assert [
               {{:set_version, 2}, _},
               {:get_integration_mode, _},
               {{:set_integration, "codspeed-elixir", "0.1.0"}, _},
               {:start_benchmark, t_start},
               {{:add_marker, ^pid, {:sample_start, _}}, _},
               {:stop_benchmark, t_stop},
               {{:executed_benchmark, ^pid, "bench/x.exs::G::fib"}, t_exec}
             ] = FakeRunner.flush()

      assert t_start < t_stop and t_stop < t_exec
    end)
  end

  @tag :clock_monotonic
  test "current_timestamp/0 is monotonic and in CLOCK_MONOTONIC nanoseconds" do
    a = Runner.current_timestamp()
    b = Runner.current_timestamp()
    assert b >= a

    os = Keyword.fetch!(:erlang.system_info(:os_monotonic_time_source), :time)
    assert_in_delta(Runner.current_timestamp(), os, 5_000_000)
  end

  @tag :clock_monotonic
  test "only walltime mode is accepted" do
    with_fake([mode: :simulation], fn fake ->
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert connect(fake) == {:disabled, {:unsupported_mode, :simulation}}
      end)

      refute Runner.connected?()
      assert Runner.start_benchmark() == :ok
    end)
  end

  test "no runner: missing FIFOs, or not running under CodSpeed" do
    assert Runner.connect(force: true, ctl_fifo: "/nonexistent/ctl", ack_fifo: "/nonexistent/ack") ==
             {:disabled, :no_runner}

    previous = System.get_env("CODSPEED_ENV")
    System.delete_env("CODSPEED_ENV")
    on_exit(fn -> if previous, do: System.put_env("CODSPEED_ENV", previous) end)
    assert Runner.connect() == {:disabled, :not_running_under_codspeed}
  end

  test "a regular file in place of a FIFO is rejected and left alone" do
    path =
      Path.join(System.tmp_dir!(), "codspeed_not_a_fifo_#{System.unique_integer([:positive])}")

    File.write!(path, "")
    on_exit(fn -> File.rm(path) end)

    assert {:disabled, {:not_a_fifo, ^path}} =
             Runner.connect(force: true, ctl_fifo: path, ack_fifo: path)

    assert File.read!(path) == ""
  end

  test "stale FIFOs without a runner do not hang" do
    id = System.unique_integer([:positive])
    ctl = Path.join(System.tmp_dir!(), "codspeed_stale_#{id}.ctl")
    ack = ctl <> ".ack"
    {_, 0} = System.cmd("mkfifo", [ctl, ack])

    on_exit(fn ->
      File.rm(ctl)
      File.rm(ack)
    end)

    {micros, result} =
      :timer.tc(fn ->
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          send(
            self(),
            {:result, Runner.connect(force: true, ctl_fifo: ctl, ack_fifo: ack, timeout: 200)}
          )
        end)

        receive do
          {:result, r} -> r
        end
      end)

    assert result == {:disabled, :no_runner}
    assert micros < 2_000_000
  end

  @tag :clock_monotonic
  test "a runner that goes silent is dropped after the timeout and calls become no-ops" do
    with_fake([silent_after: 3], fn fake ->
      assert connect(fake, timeout: 200, integration: {"x", "1"}) == :ok

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert Runner.start_benchmark() == {:error, :ack_timeout}
      end)

      Process.sleep(50)
      refute Runner.connected?()
      assert Runner.stop_benchmark() == :ok
    end)
  end

  @tag :clock_monotonic
  test "reconnecting many times works (a stale reader must not steal acks)" do
    with_fake(fn fake ->
      for _ <- 1..25 do
        assert connect(fake) == :ok
        assert Runner.start_benchmark() == :ok
        Runner.disconnect()
      end
    end)
  end
end

defmodule Benchee.CodspeedRunTest do
  use ExUnit.Case, async: false

  alias Benchee.Codspeed.Runner
  alias Benchee.Codspeed.Test.FakeRunner

  setup do
    folder = Path.join(System.tmp_dir!(), "codspeed_run_#{System.unique_integer([:positive])}")
    previous = System.get_env("CODSPEED_PROFILE_FOLDER")
    System.put_env("CODSPEED_PROFILE_FOLDER", folder)

    on_exit(fn ->
      Runner.disconnect()

      if previous,
        do: System.put_env("CODSPEED_PROFILE_FOLDER", previous),
        else: System.delete_env("CODSPEED_PROFILE_FOLDER")

      File.rm_rf(folder)
    end)

    {:ok, folder: folder}
  end

  @quiet [
    print: [benchmarking: false, configuration: false, fast_warning: false],
    formatters: [],
    warmup: 0.05,
    time: 0.1
  ]

  @tag :clock_monotonic
  test "every scenario gets one start/stop window followed by its URI, matching the results file",
       %{folder: folder} do
    fake = FakeRunner.start()
    test_pid = self()

    try do
      assert Runner.connect(
               force: true,
               ctl_fifo: fake.ctl,
               ack_fifo: fake.ack,
               integration: {"codspeed-elixir", "test"}
             ) == :ok

      jobs = %{
        "a" =>
          {fn _input -> Enum.sum(1..100) end,
           before_scenario: fn input ->
             send(test_pid, {:user, :before, Runner.current_timestamp()})
             input
           end,
           after_scenario: fn _input ->
             send(test_pid, {:user, :after, Runner.current_timestamp()})
           end},
        "b" => fn _input -> Enum.sum(1..200) end
      }

      Benchee.Codspeed.run(
        jobs,
        [
          file: "bench/x.exs",
          group: "G",
          inputs: %{"one" => 1, "two" => 2},
          parallel: 4,
          pre_check: true
        ] ++
          @quiet
      )

      cmds = FakeRunner.flush()

      assert [
               {{:set_version, 2}, _},
               {:get_integration_mode, _},
               {{:set_integration, _, _}, _} | scenario_cmds
             ] = cmds

      # parallel: 4 and pre_check: true must have been overridden: exactly 4 scenarios.
      assert length(scenario_cmds) == 12

      triples = Enum.chunk_every(scenario_cmds, 3)

      for [{:start_benchmark, t0}, {:stop_benchmark, t1}, {{:executed_benchmark, pid, _uri}, t2}] <-
            triples do
        assert pid == Runner.os_pid()
        assert t0 < t1 and t1 < t2
        # the window covers warmup (0.05 s) + measurement (0.1 s)
        assert t1 - t0 > 100_000_000
      end

      assert [_, _, _, _] = triples

      sent_uris = for [_, _, {{:executed_benchmark, _, uri}, _}] <- triples, do: uri

      results =
        [folder, "results", "*.json"]
        |> Path.join()
        |> Path.wildcard()
        |> hd()
        |> File.read!()

      json =
        if Code.ensure_loaded?(JSON),
          do: apply(JSON, :decode!, [results]),
          else: apply(Jason, :decode!, [results])

      file_uris = Enum.map(json["benchmarks"], & &1["uri"])

      assert Enum.sort(sent_uris) == Enum.sort(file_uris)

      assert Enum.sort(file_uris) == [
               "bench/x.exs::G::a[one]",
               "bench/x.exs::G::a[two]",
               "bench/x.exs::G::b[one]",
               "bench/x.exs::G::b[two]"
             ]

      # The user's own hooks still run (once per input), and never inside a profiled window.
      windows =
        for [{:start_benchmark, from}, {:stop_benchmark, to}, _] <- triples, do: {from, to}

      user_before = collect_user_hooks(:before)
      user_after = collect_user_hooks(:after)
      assert length(user_before) == 2
      assert length(user_after) == 2

      for ts <- user_before ++ user_after do
        refute Enum.any?(windows, fn {from, to} -> from <= ts and ts <= to end),
               "user hook at #{ts} ran inside a profiled window #{inspect(windows)}"
      end

      # ...and each one sits right next to "its" window: before it opens / after it closes.
      for ts <- user_before,
          do: assert(Enum.any?(windows, fn {from, _} -> ts < from and from - ts < 50_000_000 end))

      for ts <- user_after,
          do: assert(Enum.any?(windows, fn {_, to} -> ts > to and ts - to < 50_000_000 end))
    after
      Runner.disconnect()
      FakeRunner.stop(fake)
    end
  end

  defp collect_user_hooks(kind, acc \\ []) do
    receive do
      {:user, ^kind, ts} -> collect_user_hooks(kind, [ts | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "without a runner it is plain Benchee plus the results file", %{folder: folder} do
    previous = System.get_env("CODSPEED_ENV")
    System.delete_env("CODSPEED_ENV")
    on_exit(fn -> if previous, do: System.put_env("CODSPEED_ENV", previous) end)

    Benchee.Codspeed.run(%{"a" => fn -> Enum.sum(1..10) end}, [file: "bench/y.exs"] ++ @quiet)

    refute Runner.connected?()
    assert [_one_file] = Path.wildcard(Path.join([folder, "results", "*.json"]))
  end
end
