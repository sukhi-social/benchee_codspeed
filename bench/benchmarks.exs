# Benchmarks of benchee_codspeed itself, measured with benchee_codspeed.
#
# Run them locally:
#
#     mix run bench/benchmarks.exs
#
# Run them with the CodSpeed CLI (walltime mode, Linux only):
#
#     codspeed run -m walltime -- mix run bench/benchmarks.exs

alias Benchee.Codspeed
alias Benchee.Codspeed.Protocol

bench_opts = [warmup: 1, time: 3, memory_time: 0, reduction_time: 0, print: [fast_warning: false]]

# -- Protocol ----------------------------------------------------------------
# One frame is sent per runner command, so encoding and decoding sit on the
# path of every profiled scenario.

uri = "bench/benchmarks.exs::Formatter::format[10_000 samples]"
pid = 123_456

commands = [
  {:set_version, Protocol.protocol_version()},
  :get_integration_mode,
  {:set_integration, "codspeed-elixir", "0.1.0"},
  :start_benchmark,
  :stop_benchmark,
  {:executed_benchmark, pid, uri},
  {:add_marker, pid, {:sample_start, 1_000_000}},
  {:add_marker, pid, {:sample_end, 2_000_000}},
  {:integration_mode_response, :walltime}
]

bodies = Enum.map(commands, &Protocol.encode/1)
stream = commands |> Enum.map(&Protocol.frame/1) |> IO.iodata_to_binary()

unframe_all = fn
  _fun, buffer, acc when buffer == "" ->
    acc

  fun, buffer, acc ->
    {:ok, body, rest} = Protocol.unframe(buffer)
    fun.(fun, rest, [body | acc])
end

Codspeed.run(
  %{
    "frame_all_commands" => fn -> Enum.map(commands, &Protocol.frame/1) end,
    "decode_all_commands" => fn -> Enum.map(bodies, &Protocol.decode/1) end,
    "unframe_stream" => fn -> unframe_all.(unframe_all, stream, []) end
  },
  [file: "bench/benchmarks.exs", group: "Protocol"] ++ bench_opts
)

# -- Formatter ---------------------------------------------------------------
# The formatter turns raw Benchee samples into the CodSpeed walltime results
# (sorting, quantiles, standard deviation and outlier counts).

suite_with_samples = fn sample_count ->
  :rand.seed(:exsss, {1, 2, 3})

  scenarios =
    for job <- ["job_a", "job_b"] do
      samples = for _ <- 1..sample_count, do: 1_000 + :rand.uniform(500)

      %Benchee.Scenario{
        name: job,
        job_name: job,
        input_name: Benchee.Benchmark.no_input(),
        run_time_data: %Benchee.CollectionData{samples: samples}
      }
    end

  %Benchee.Suite{
    scenarios: scenarios,
    configuration: %Benchee.Configuration{warmup: 1.0e9, time: 3.0e9}
  }
end

format_opts = %{file: "bench/benchmarks.exs", group: "Example"}

Codspeed.run(
  %{
    "format" => fn suite -> Codspeed.format(suite, format_opts) end
  },
  [
    file: "bench/benchmarks.exs",
    group: "Formatter",
    inputs: [
      {"1_000 samples", suite_with_samples.(1_000)},
      {"100_000 samples", suite_with_samples.(100_000)}
    ]
  ] ++ bench_opts
)

# -- URIs --------------------------------------------------------------------

Codspeed.run(
  %{
    "benchmark_uri" => fn ->
      Codspeed.benchmark_uri("bench/benchmarks.exs", "Group", "job", "input")
    end
  },
  [file: "bench/benchmarks.exs", group: "Uri"] ++ bench_opts
)
