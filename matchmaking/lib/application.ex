defmodule Matchmaking.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children = [
      {Middleware.Worker, []},
      {Requeue.Worker, []}
    ]

    opts = [strategy: :one_for_one, name: Matchmaking.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
