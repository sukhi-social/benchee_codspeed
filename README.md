# benchee_codspeed

[![CodSpeed](https://img.shields.io/endpoint?url=https://codspeed.io/badge.json)](https://app.codspeed.io/sukhi-social/benchee_codspeed?utm_source=badge)

This library connects [Benchee](https://hex.pm/packages/benchee) to
[CodSpeed](https://codspeed.io). It supports walltime mode only.

The library does two jobs:

1. It writes the Benchee results in the CodSpeed walltime format.
2. It tells the CodSpeed runner when each benchmark starts and stops.
   The runner then records `perf` samples for that benchmark only.

Outside CodSpeed, the library does nothing. The same script runs on your
computer without change.

## Requirements

- Elixir 1.15 or later.
- Benchee 1.3 or later.
- For profiling: the CodSpeed runner on Linux, in walltime mode.

Elixir 1.17 and earlier have no `JSON` module. For these versions, add the
`:jason` package to your dependencies.

## Installation

The package is not on Hex yet. Add it from GitHub to the dependencies in
`mix.exs`:

```elixir
{:benchee_codspeed, github: "sukhi-social/benchee_codspeed", only: :dev}
```

## Usage

Replace `Benchee.run/2` with `Benchee.Codspeed.run/2`:

```elixir
Benchee.Codspeed.run(
  %{
    "fib_20" => fn -> Fib.run(20) end,
    "fib_25" => fn -> Fib.run(25) end
  },
  file: "bench/fib_bench.exs",
  group: "Fib",
  warmup: 1,
  time: 3
)
```

Run the script with the CodSpeed CLI:

```bash
codspeed run -m walltime -- mix run bench/fib_bench.exs
```

Or use the CodSpeed GitHub Action with `mode: walltime`.

## Options

`Benchee.Codspeed.run/2` has two options of its own. It sends all other
options to Benchee.

| Option   | Meaning                                         | Default                  |
| -------- | ----------------------------------------------- | ------------------------ |
| `:file`  | Path of the benchmark file, from the git root.  | `"bench/benchmarks.exs"` |
| `:group` | Name of a group of benchmarks (optional).       | none                     |

The URI of a benchmark is `file::group::name`. If you use Benchee inputs,
the name is `job[input]`.

By default, Benchee uses the console formatter. The library adds its own
formatter to the list. Do not add it yourself.

## Formatter only

To get the results file without profiling, add the formatter to the
`:formatters` option of `Benchee.run/2`:

```elixir
Benchee.run(jobs,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Codspeed, file: "bench/fib_bench.exs"}
  ]
)
```

The formatter has the same `:file` and `:group` options. It has one more
option, `:profile_folder`. This option replaces `CODSPEED_PROFILE_FOLDER`.

## Results file

The formatter writes the results to this path:

```text
$CODSPEED_PROFILE_FOLDER/results/<pid>.json
```

`<pid>` is the ID of the operating system process. Several calls to `run/2`
in one process write to the same file. If `CODSPEED_PROFILE_FOLDER` is not
set, the formatter writes no file.

## Profiling

The library connects to the runner only when the environment variable
`CODSPEED_ENV` is set. If the connection fails, the library prints a warning.
The benchmarks then run without profiling, and the results file is still
written.

When the connection works, `run/2` profiles each scenario. A scenario is one
job with one input. The profiled window covers the whole scenario. This
includes the Benchee warmup.

Profiling windows must not overlap. For this reason, `run/2` sets
`parallel: 1` and `pre_check: false`. Your own `before_scenario` and
`after_scenario` hooks stay in place. Their setup runs before the window
opens. Their teardown runs after the window closes.

To see the names of BEAM functions in the flame graph, start the VM with the
perf map:

```bash
ELIXIR_ERL_OPTIONS="+JPperf true" codspeed run -m walltime -- mix run bench/fib_bench.exs
```

## Limits

- The runner works on Linux only.
- The library does not set markers inside a profiling window.
- The library does not support `__codspeed_root_frame__`.
- Two inputs can have the same value under different names. The library
  cannot tell them apart. It prints a warning, and the profile can go to
  the wrong benchmark.

## Modules

| Module                      | Purpose                                              |
| --------------------------- | ---------------------------------------------------- |
| `Benchee.Codspeed`          | Formatter, `run/2`, and statistics.                  |
| `Benchee.Codspeed.Runner`   | Client for the FIFO protocol of the runner.          |
| `Benchee.Codspeed.Protocol` | Wire format of the protocol. It has no side effects. |

## Development

```bash
mix deps.get
mix test
mix format --check-formatted
```

The file `bench/benchmarks.exs` has benchmarks of the library. They use the
library itself. To run them:

```bash
mix run bench/benchmarks.exs
```

The `codspeed` workflow runs them on CodSpeed macro runners, in walltime mode.

The runner uses the clock `CLOCK_MONOTONIC`. The BEAM on macOS uses a
different clock. Six tests use a fake runner and need `CLOCK_MONOTONIC`.
These tests have the tag `clock_monotonic`. ExUnit skips them on systems
other than Linux.

## License

This library has the MIT license. Read the file `LICENSE`.
