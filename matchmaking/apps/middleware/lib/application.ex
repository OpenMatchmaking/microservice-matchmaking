defmodule Middleware.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children = [
      {Middleware.Worker, []},
    ]

    opts = [strategy: :one_for_one, name: Middleware.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
