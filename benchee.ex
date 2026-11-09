defmodule CodSpeed.Benchee do
  @moduledoc """
  A [Benchee](https://hex.pm/packages/benchee) formatter that reports results to
  [CodSpeed](https://codspeed.io) in **walltime** mode.

  It converts the raw samples Benchee collected into the CodSpeed walltime JSON
  (`WalltimeResults` in the CodSpeed runner) and writes it to
  `$CODSPEED_PROFILE_FOLDER/results/<os pid>.json`, which is where the runner
  picks results up.

  When `CODSPEED_PROFILE_FOLDER` is not set (e.g. on your laptop) the formatter
  does nothing, so it is safe to leave it in your benchmark script next to the
  console formatter.

  ## Usage

      Benchee.run(
        %{
          "fib_20" => fn -> Fib.run(20) end,
          "fib_25" => fn -> Fib.run(25) end
        },
        warmup: 1,
        time: 3,
        formatters: [
          Benchee.Formatters.Console,
          {CodSpeed.Benchee, file: "bench/fib_bench.exs", group: "Fib"}
        ]
      )

  Run it through the CodSpeed CLI (or the GitHub Action with `mode: walltime`):

      codspeed run -m walltime -- mix run bench/fib_bench.exs

  ## Options

    * `:file` - path of the benchmark file, relative to the git root. Used to
      build the benchmark URI (`file::group::name`). Default: `"bench/benchmarks.exs"`.
    * `:group` - optional group name, inserted into the URI.
    * `:profile_folder` - overrides `CODSPEED_PROFILE_FOLDER`.

  Calling `Benchee.run/2` several times in one script is fine: results written
  by the same OS process are merged into the same file.

  ## Limitations

  Only the results file is written. The runner's FIFO protocol (used to tie
  profiler samples to benchmarks) is not implemented, so the runner prints a
  "failed to detect benchmarks" profiling warning. Set
  `CODSPEED_PROFILER_ENABLED=false` to silence it.
  """

  @behaviour Benchee.Formatter

  @version "0.1.0"
  @iqr_factor 1.5
  # The CodSpeed runner (runner-shared/walltime_results/stats.rs) uses 2 sigma.
  @stdev_factor 2.0

  @impl true
  def format(suite, opts) do
    # Benchee hands formatter options over as a map (DeepConvert.to_map/1),
    # but be lenient and accept keyword lists too.
    opts = Map.new(opts)
    file = Map.get(opts, :file, "bench/benchmarks.exs")
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
    name = name(scenario)

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
      uri: [file, group, name] |> Enum.reject(&is_nil/1) |> Enum.join("::"),
      config: run_config,
      stats: stats(samples(scenario))
    }
  end

  defp name(%{job_name: job, input_name: input}) do
    if input == Benchee.Benchmark.no_input(), do: job, else: "#{job}[#{input}]"
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
