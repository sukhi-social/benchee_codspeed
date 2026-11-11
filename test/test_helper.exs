# The CodSpeed runner is Linux-only and speaks in CLOCK_MONOTONIC. Elsewhere (macOS uses
# CLOCK_UPTIME_RAW) the tests that go through the fake runner cannot run.
clock = :erlang.system_info(:os_monotonic_time_source) |> Keyword.get(:clock_id)
exclude = if clock == :CLOCK_MONOTONIC, do: [], else: [:clock_monotonic]

ExUnit.start(exclude: exclude)
