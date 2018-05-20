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
      {:spotter, "~> 0.4.1"},
      {:poison, "~> 3.1"},
      {:mnesiam, "~> 0.1.1"},
      {:libcluster, "~> 2.1"},
      {:uuid, "~> 1.1" }
    ]
  end
end
