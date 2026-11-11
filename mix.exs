defmodule BencheeCodSpeed.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :benchee_codspeed,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "CodSpeed for Elixir",
      description: "CodSpeed walltime integration for Benchee."
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:benchee, "~> 1.3"},
      # Only needed on Elixir < 1.18, which has no built-in JSON module.
      {:jason, "~> 1.4", optional: true}
    ]
  end
end
