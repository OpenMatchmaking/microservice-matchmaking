defmodule Matchmaking.Application do
  @moduledoc false
  use Application

  @config Confex.fetch_env!(:matchmaking, __MODULE__)

  def start(_type, _args) do
    IO.puts "#{inspect @config}"

    import Supervisor.Spec, warn: false
    
    children = [
      # Start the AMQP connection
      supervisor(Matchmaking.AMQP.Connection, []),
      # Start the Middleware and workers
      worker(Matchmaking.Middleware.Worker, []),
      worker(Matchmaking.Requeue.Worker, [])
    ]

    IO.puts "#{inspect length(children)}"

    opts = [strategy: :one_for_one, name: Matchmaking.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
