defmodule Tamale.MixProject do
  use Mix.Project

  @version "0.1.0"
  @description "A minimal kernel for preserving user edits across upstream regeneration cycles"

  def project do
    [
      app: :tamale,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: [precommit: ["compile --warnings-as-errors", "format", "test"]],
      deps: deps(),
      description: @description
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  def cli do
    [preferred_envs: ["test.another": :test]]
  end

  defp deps do
    []
  end
end
