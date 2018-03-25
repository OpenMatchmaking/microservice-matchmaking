defmodule Matchmaking.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false
    
    children = [
      # Start the AMQP connection
      supervisor(Matchmaking.AMQP.Connection, []),
      # Start the Middleware and workers
      worker(Matchmaking.Middleware.Worker, []),
      worker(Matchmaking.Requeue.Worker, [])
    ]

    opts = [strategy: :one_for_one, name: Matchmaking.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
