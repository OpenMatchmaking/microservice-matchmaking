defmodule Middleware.MixProject do
  use Mix.Project

  def project do
    [
      app: :middleware,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [],
      mod: {Middleware.Application, []}
    ]
  end

  defp deps do
    [
      {:spotter, "~> 0.1.1"},
      {:poison, "~> 3.1"}
    ]
  end
end
