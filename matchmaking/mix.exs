defmodule Middleware.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :matchmaking,
      version: @version,
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:spotter, :libcluster, :mnesiam],
      mod: {Matchmaking.Application, []}
    ]
  end

  defp deps do
    [
      {:spotter, "~> 0.5.0"},
      {:poison, "~> 4.0"},
      {:mnesiam, "~> 0.1.1"},
      {:libcluster, "~> 3.0"},
      {:uuid, "~> 1.1" }
    ]
  end
end
