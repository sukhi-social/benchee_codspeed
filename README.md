# benchee_codspeed

[Benchee](https://hex.pm/packages/benchee) を [CodSpeed](https://codspeed.io) の
**walltime モード**につなぐ、Elixir のライブラリです。

ふたつのことをします。

1. **結果**: Benchee の測定値を CodSpeed の walltime JSON にして、
   `$CODSPEED_PROFILE_FOLDER/results/<os pid>.json` に書く。
2. **プロファイル**（あれば）: runner と FIFO で話して、各ベンチマークが走っている間だけ
   `perf` にサンプルを取ってもらい、フレームグラフの正しいベンチマークに結びつける。

CodSpeed の外（`CODSPEED_PROFILE_FOLDER` も runner も無いとき）では、どちらも何もしません。
おなじスクリプトが、手元でもそのまま動きます。

## 使いかた

`CodSpeed.Benchee.run/2` は、`Benchee.run/2` に CodSpeed がついたものです。

```elixir
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
```

`:file`（git ルートからの相対パス）と `:group` が CodSpeed 用で、ほかは Benchee に渡ります。
CodSpeed CLI から走らせます。

```bash
codspeed run -m walltime -- mix run bench/fib_bench.exs
```

結果ファイルだけがほしいときは、フォーマッタとして直接足せます。

```elixir
Benchee.run(jobs,
  formatters: [Benchee.Formatters.Console, {CodSpeed.Benchee, file: "bench/fib_bench.exs"}]
)
```

BEAM のコードにシンボル名をつけたいときは、perf map を有効にして起動します
（`ELIXIR_ERL_OPTIONS="+JPperf true"`）。

詳しい仕様と制限は、`lib/codspeed/benchee.ex` の moduledoc に書いてあります。

## 構成

| ファイル | 役目 |
|---|---|
| `lib/codspeed/benchee.ex` | Benchee のフォーマッタと `run/2`（統計と結果ファイル） |
| `lib/codspeed/runner.ex` | runner の FIFO プロトコルのクライアント（GenServer） |
| `lib/codspeed/protocol.ex` | ワイヤ形式（bincode 1.x）。副作用なしの関数だけ |

## 開発

```bash
mix deps.get
mix test
mix format --check-formatted
```

runner は Linux 専用で、時刻に `CLOCK_MONOTONIC` を使います。macOS の BEAM は別の時計
（`CLOCK_UPTIME_RAW`）なので、fake runner を通る 6 つのテスト（`@tag :clock_monotonic`）は
Linux 以外では除外されます。Linux では全部走ります。

JSON は Elixir 1.18 以降なら組み込みの `JSON`、それより古ければ `:jason` を使います。

## TODO

- モジュール名を `Benchee.Codspeed` に改名する（いまは `CodSpeed.Benchee`）
