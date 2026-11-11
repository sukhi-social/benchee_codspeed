defmodule CodSpeed.Benchee do
  @moduledoc """
  [Benchee](https://hex.pm/packages/benchee) integration for
  [CodSpeed](https://codspeed.io) in **walltime** mode.

  It does two things:

    1. **Results**: a Benchee formatter that converts the raw samples into the
       CodSpeed walltime JSON and writes it to
       `$CODSPEED_PROFILE_FOLDER/results/<os pid>.json`.
    2. **Profiling** (optional): `run/2` also talks to the runner over its FIFO
       protocol (`CodSpeed.Runner`) so that `perf` samples are recorded while each
       benchmark runs and are attached to the right benchmark in the flame graph.

  Outside of CodSpeed (no `CODSPEED_PROFILE_FOLDER`, no runner) both parts do
  nothing, so the same script runs fine on your laptop.

  ## Usage

  `run/2` is `Benchee.run/2` plus CodSpeed:

      CodSpeed.Benchee.run(
        %{
          "fib_20" => fn -> Fib.run(20) end,
          "fib_25" => fn -> Fib.run(25) end
        },
        file: "bench/fib_bench.exs",
        group: "Fib",
        warmup: 1,
        time: 3
      )

  `:file` and `:group` are CodSpeed options, everything else goes to Benchee
  (`:formatters` defaults to the console formatter; the CodSpeed formatter is
  added for you). Run it through the CodSpeed CLI, or the GitHub Action with
  `mode: walltime`:

      codspeed run -m walltime -- mix run bench/fib_bench.exs

  If you only want the results file, use the formatter directly:

      Benchee.run(jobs,
        formatters: [Benchee.Formatters.Console, {CodSpeed.Benchee, file: "bench/fib_bench.exs"}]
      )

  ## Options

    * `:file` - path of the benchmark file, relative to the git root. Used to
      build the benchmark URI (`file::group::name`). Default: `"bench/benchmarks.exs"`.
    * `:group` - optional group name, inserted into the URI.
    * `:profile_folder` - formatter only; overrides `CODSPEED_PROFILE_FOLDER`.

  Calling `run/2` several times in one script is fine: results written by the
  same OS process are merged into the same file.

  ## Profiling details and limitations

  While connected to a runner, `run/2` adds a `before_scenario` / `after_scenario`
  hook to every job. The profiled window is the **whole scenario**, so it
  includes Benchee's warmup. Because windows must not overlap, `run/2` forces
  `parallel: 1` and `pre_check: false` in that case. Your own job hooks are kept
  (their setup runs before the window opens, their teardown after it closes).

  Not implemented: markers inside a window, and `__codspeed_root_frame__`.
  To get symbol names for BEAM code in the flame graph, start the VM with the
  perf map enabled, for example `ELIXIR_ERL_OPTIONS="+JPperf true"`.
  """

  @behaviour Benchee.Formatter

  @version "0.1.0"
  @iqr_factor 1.5
  # The CodSpeed runner (runner-shared/walltime_results/stats.rs) uses 2 sigma.
  @stdev_factor 2.0

  @default_file "bench/benchmarks.exs"
  @uri_key {__MODULE__, :uri}

  @doc """
  Runs `Benchee.run/2` and reports to CodSpeed. See the module documentation.
  """
  @spec run(map() | [{String.t(), term()}], keyword()) :: any()
  def run(benchmarks, opts \\ []) do
    {own, bench_opts} = Keyword.split(opts, [:file, :group])
    file = Keyword.get(own, :file, @default_file)
    group = Keyword.get(own, :group)

    instrumented? = CodSpeed.Runner.connect(integration: {"codspeed-elixir", @version}) == :ok

    formatters =
      Keyword.get(bench_opts, :formatters, [Benchee.Formatters.Console]) ++
        [{__MODULE__, file: file, group: group}]

    bench_opts = Keyword.put(bench_opts, :formatters, formatters)

    if instrumented? do
      jobs = instrument(benchmarks, Keyword.get(bench_opts, :inputs), file, group)
      # Profiling windows must not overlap and must contain only the real run.
      Benchee.run(jobs, bench_opts |> Keyword.put(:parallel, 1) |> Keyword.put(:pre_check, false))
    else
      Benchee.run(benchmarks, bench_opts)
    end
  end

  @doc """
  The benchmark URI used both in the results file and when telling the runner
  which benchmark just ran. They have to match.
  """
  @spec benchmark_uri(String.t(), String.t() | nil, String.t(), term()) :: String.t()
  def benchmark_uri(file, group, job_name, input_name) do
    [file, group, scenario_name(job_name, input_name)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("::")
  end

  defp scenario_name(job, input) do
    if input == Benchee.Benchmark.no_input(), do: job, else: "#{job}[#{input}]"
  end

  # -- profiling hooks ---------------------------------------------------------

  defp instrument(benchmarks, inputs, file, group) do
    input_names = input_name_lookup(inputs)

    wrapped =
      Enum.map(benchmarks, fn {job_name, job} ->
        {job_name, wrap_job(job, job_name, input_names, file, group)}
      end)

    if is_map(benchmarks), do: Map.new(wrapped), else: wrapped
  end

  # Hooks receive the input *value*, the results use the input *name*.
  defp input_name_lookup(nil), do: %{}

  defp input_name_lookup(inputs) do
    inputs
    |> Enum.group_by(fn {_name, value} -> value end, fn {name, _value} -> name end)
    |> Enum.flat_map(fn
      {value, [name]} -> [{value, name}]
      {_value, _ambiguous} -> []
    end)
    |> Map.new()
  end

  defp wrap_job(job, job_name, input_names, file, group) do
    {fun, job_opts} = split_job(job)
    user_before = Keyword.get(job_opts, :before_scenario)
    user_after = Keyword.get(job_opts, :after_scenario)

    before_scenario = fn input ->
      Process.put(@uri_key, benchmark_uri(file, group, job_name, input_name(input_names, input)))
      input = if user_before, do: user_before.(input), else: input
      CodSpeed.Runner.start_benchmark()
      input
    end

    after_scenario = fn input ->
      CodSpeed.Runner.stop_benchmark()
      CodSpeed.Runner.set_executed_benchmark(Process.delete(@uri_key))
      if user_after, do: user_after.(input)
      :ok
    end

    {fun,
     job_opts
     |> Keyword.put(:before_scenario, before_scenario)
     |> Keyword.put(:after_scenario, after_scenario)}
  end

  defp split_job({fun, opts}) when is_function(fun) and is_list(opts), do: {fun, opts}
  defp split_job(fun) when is_function(fun), do: {fun, []}

  defp input_name(input_names, input) do
    cond do
      input == Benchee.Benchmark.no_input() ->
        input

      Map.has_key?(input_names, input) ->
        Map.fetch!(input_names, input)

      true ->
        warn_unknown_input(input)
        inspect(input)
    end
  end

  defp warn_unknown_input(input) do
    key = {__MODULE__, :warned_input}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)

      IO.puts(
        :stderr,
        "[codspeed] could not tell which input #{inspect(input)} belongs to " <>
          "(same value under several names, or changed by a global before_scenario hook); " <>
          "its profile may not be attached to the right benchmark"
      )
    end
  end

  @impl true
  def format(suite, opts) do
    # Benchee hands formatter options over as a map (DeepConvert.to_map/1),
    # but be lenient and accept keyword lists too.
    opts = Map.new(opts)
    file = Map.get(opts, :file, @default_file)
    group = Map.get(opts, :group)

    benchmarks =
      suite.scenarios
      |> Enum.reject(&(samples(&1) == []))
      |> Enum.map(&benchmark(&1, file, group, suite.configuration))

    %{
      creator: %{name: "codspeed-elixir", version: @version, pid: os_pid()},
      instrument: %{type: "walltime"},
      benchmarks: benchmarks
    }
  end

  @impl true
  def write(report, opts) do
    case profile_folder(Map.new(opts)) do
      nil ->
        :ok

      folder ->
        dir = Path.join(folder, "results")
        path = Path.join(dir, "#{os_pid()}.json")

        with :ok <- File.mkdir_p(dir),
             :ok <- File.write(path, encode!(merge_existing(report, path))) do
          :ok
        else
          {:error, reason} ->
            {:error, "CodSpeed: could not write #{path}: #{inspect(reason)}"}
        end
    end
  end

  # -- building the report ---------------------------------------------------

  defp benchmark(scenario, file, group, config) do
    name = scenario_name(scenario.job_name, scenario.input_name)

    run_config =
      [
        warmup_time_ns: config_ns(config, :warmup),
        max_time_ns: config_ns(config, :time),
        min_round_time_ns: 0
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %{
      name: name,
      uri: benchmark_uri(file, group, scenario.job_name, scenario.input_name),
      config: run_config,
      stats: stats(samples(scenario))
    }
  end

  # Benchee converts :time / :warmup to nanoseconds (floats) when it builds its config.
  defp config_ns(config, key) do
    case Map.get(config, key) do
      n when is_number(n) -> trunc(n)
      _ -> nil
    end
  end

  defp samples(%{run_time_data: %{samples: samples}}) when is_list(samples), do: samples
  defp samples(_), do: []

  # -- statistics -------------------------------------------------------------
  # Benchee samples are nanoseconds *per call* (it already divides repeated
  # measurements by their repeat count), hence iter_per_round: 1.
  # The maths mirrors the CodSpeed runner / pytest-codspeed:
  # sample stdev (n-1), "exclusive" quantiles, 1.5*IQR and 2-sigma outliers.

  defp stats(samples) do
    sorted = Enum.sort(samples)
    n = length(sorted)
    sum = Enum.sum(sorted)
    mean = sum / n
    stdev = std_dev(sorted, mean, n)

    tuple = List.to_tuple(sorted)
    q1 = quantile(tuple, n, 0.25)
    q3 = quantile(tuple, n, 0.75)
    iqr = q3 - q1
    {low, high} = {q1 - @iqr_factor * iqr, q3 + @iqr_factor * iqr}

    %{
      min_ns: List.first(sorted) * 1.0,
      max_ns: List.last(sorted) * 1.0,
      mean_ns: mean,
      stdev_ns: stdev,
      q1_ns: q1,
      median_ns: median(tuple, n),
      q3_ns: q3,
      rounds: n,
      # in seconds
      total_time: sum / 1.0e9,
      iqr_outlier_rounds: Enum.count(sorted, &(&1 < low or &1 > high)),
      stdev_outlier_rounds: Enum.count(sorted, &(abs(&1 - mean) > @stdev_factor * stdev)),
      iter_per_round: 1,
      warmup_iters: 0
    }
  end

  defp std_dev(_sorted, _mean, n) when n < 2, do: 0.0

  defp std_dev(sorted, mean, n) do
    variance = Enum.reduce(sorted, 0.0, fn x, acc -> acc + (x - mean) * (x - mean) end) / (n - 1)
    :math.sqrt(variance)
  end

  defp median(tuple, n) do
    mid = div(n, 2)

    if rem(n, 2) == 0 do
      (elem(tuple, mid - 1) + elem(tuple, mid)) / 2
    else
      elem(tuple, mid) * 1.0
    end
  end

  defp quantile(tuple, 1, _p), do: elem(tuple, 0) * 1.0
  defp quantile(tuple, 2, p), do: elem(tuple, 0) * (1.0 - p) + elem(tuple, 1) * p

  defp quantile(tuple, n, p) do
    pos = p * (n + 1) - 1
    idx = trunc(pos)
    frac = pos - idx

    if idx + 1 < n do
      elem(tuple, idx) * (1.0 - frac) + elem(tuple, idx + 1) * frac
    else
      elem(tuple, min(idx, n - 1)) * 1.0
    end
  end

  # -- file handling ---------------------------------------------------------

  defp profile_folder(opts) do
    case Map.get(opts, :profile_folder) || System.get_env("CODSPEED_PROFILE_FOLDER") do
      nil -> nil
      "" -> nil
      folder -> folder
    end
  end

  # System.pid/0 only exists since Elixir 1.9; Benchee still supports ~> 1.6.
  defp os_pid, do: :os.getpid() |> List.to_string() |> String.to_integer()

  # Several Benchee.run/2 calls in one process share one results file.
  defp merge_existing(report, path) do
    with true <- File.exists?(path),
         {:ok, binary} <- File.read(path),
         %{"benchmarks" => previous} when is_list(previous) <- decode!(binary) do
      Map.update!(report, :benchmarks, &(previous ++ &1))
    else
      _ -> report
    end
  end

  # Elixir >= 1.18 ships `JSON`; older versions can use Jason.
  defp encode!(term) do
    cond do
      Code.ensure_loaded?(JSON) -> apply(JSON, :encode!, [term])
      Code.ensure_loaded?(Jason) -> apply(Jason, :encode!, [term])
      true -> raise "CodSpeed.Benchee needs Elixir >= 1.18 (JSON) or the :jason package"
    end
  end

  defp decode!(binary) do
    cond do
      Code.ensure_loaded?(JSON) -> apply(JSON, :decode!, [binary])
      Code.ensure_loaded?(Jason) -> apply(Jason, :decode!, [binary])
      true -> raise "CodSpeed.Benchee needs Elixir >= 1.18 (JSON) or the :jason package"
    end
  end
end
