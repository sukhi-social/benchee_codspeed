defmodule CodSpeed.BencheeTest do
  use ExUnit.Case, async: false

  # Expected values are taken from the unit tests of the CodSpeed runner
  # (crates/runner-shared/src/walltime_results/stats.rs), so this formatter
  # stays numerically in line with what CodSpeed itself computes.

  defp scenario(job, samples, input \\ Benchee.Benchmark.no_input()) do
    %{job_name: job, input_name: input, run_time_data: %{samples: samples}}
  end

  defp suite(scenarios) do
    %{configuration: %{warmup: 2.0e9, time: 5.0e9}, scenarios: scenarios}
  end

  defp stats_for(samples) do
    # Benchee passes formatter options as a map.
    %{benchmarks: [%{stats: stats}]} =
      CodSpeed.Benchee.format(suite([scenario("x", samples)]), %{file: "f"})

    stats
  end

  defp assert_close(actual, expected), do: assert_in_delta(actual, expected, 1.0e-9)

  test "basic stats (right-skewed data)" do
    s = stats_for([100, 200, 300, 400, 600])
    assert_close(s.min_ns, 100.0)
    assert_close(s.max_ns, 600.0)
    assert_close(s.mean_ns, 320.0)
    assert_close(s.median_ns, 300.0)
    assert_close(s.q1_ns, 150.0)
    assert_close(s.q3_ns, 500.0)
    assert_close(s.stdev_ns, :math.sqrt(37_000))
    assert s.rounds == 5
    assert s.iqr_outlier_rounds == 0
    assert s.stdev_outlier_rounds == 0
    assert s.iter_per_round == 1
    assert_close(s.total_time, 1600.0 / 1.0e9)
  end

  test "2-sigma outlier detection" do
    s = stats_for(List.duplicate(1, 16) ++ [50])
    assert_close(s.mean_ns, 3.8823529411764706)
    assert_close(s.median_ns, 1.0)
    assert_close(s.stdev_ns, 11.884245626780316)
    assert s.stdev_outlier_rounds == 1
  end

  test "IQR outlier detection" do
    s = stats_for([100, 110, 120, 130, 140, 500])
    assert_close(s.q1_ns, 107.5)
    assert_close(s.q3_ns, 230.0)
    assert s.iqr_outlier_rounds == 1
  end

  test "exclusive quantiles for odd and even sample counts" do
    s = stats_for(Enum.map(1..9, &(&1 * 10)))
    assert {s.q1_ns, s.median_ns, s.q3_ns} == {25.0, 50.0, 75.0}

    s = stats_for(Enum.map(1..8, &(&1 * 10)))
    assert {s.q1_ns, s.median_ns, s.q3_ns} == {22.5, 45.0, 67.5}
  end

  test "one and two samples" do
    s = stats_for([100])

    assert {s.min_ns, s.mean_ns, s.median_ns, s.q1_ns, s.q3_ns} ==
             {100.0, 100.0, 100.0, 100.0, 100.0}

    assert s.stdev_ns == 0.0
    assert s.rounds == 1

    s = stats_for([100, 200])
    assert_close(s.median_ns, 150.0)
    assert_close(s.stdev_ns, 70.71067811865476)
  end

  test "names, uris and config" do
    report =
      CodSpeed.Benchee.format(
        suite([
          scenario("fib", [1, 2, 3]),
          scenario("fib", [1, 2, 3], "big"),
          scenario("memory_only", [])
        ]),
        %{file: "bench/fib_bench.exs", group: "Fib"}
      )

    assert [a, b] = report.benchmarks
    assert {a.name, a.uri} == {"fib", "bench/fib_bench.exs::Fib::fib"}
    assert {b.name, b.uri} == {"fib[big]", "bench/fib_bench.exs::Fib::fib[big]"}

    assert a.config == %{
             warmup_time_ns: 2_000_000_000,
             max_time_ns: 5_000_000_000,
             min_round_time_ns: 0
           }

    assert report.instrument == %{type: "walltime"}
  end

  describe "write/2" do
    setup do
      folder =
        Path.join(System.tmp_dir!(), "codspeed_benchee_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(folder) end)
      {:ok, folder: folder}
    end

    test "is a no-op without a profile folder", %{folder: folder} do
      System.delete_env("CODSPEED_PROFILE_FOLDER")
      report = CodSpeed.Benchee.format(suite([scenario("x", [1, 2, 3])]), %{})
      assert CodSpeed.Benchee.write(report, %{}) == :ok
      refute File.exists?(folder)
    end

    test "writes results/<pid>.json and merges repeated runs", %{folder: folder} do
      report = CodSpeed.Benchee.format(suite([scenario("x", [1, 2, 3])]), %{})
      opts = %{profile_folder: folder}

      assert CodSpeed.Benchee.write(report, opts) == :ok
      assert CodSpeed.Benchee.write(report, opts) == :ok

      assert [path] = Path.wildcard(Path.join(folder, "results/*.json"))
      assert Path.basename(path, ".json") == :os.getpid() |> List.to_string()

      json = File.read!(path)
      json_module = if Code.ensure_loaded?(JSON), do: JSON, else: Jason
      decoded = apply(json_module, :decode!, [json])
      assert length(decoded["benchmarks"]) == 2
    end
  end
end
