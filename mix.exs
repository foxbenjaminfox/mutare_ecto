defmodule Mutare.Ecto.MixProject do
  use Mix.Project

  def project do
    [
      app: :mutare_ecto,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "Mutation-testing plugin for Ecto — a Mutare custom mutator.",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:mutare, path: "../mutare5"},
      {:ecto, "~> 3.10"}
    ]
  end
end
