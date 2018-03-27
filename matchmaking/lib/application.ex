defmodule Matchmaking.Application do
  @moduledoc false
  use Application

  @config Confex.fetch_env!(:matchmaking, __MODULE__)

  # Spawn workers depends of the specified concurrency
  defp spawn_workers(module, concurrency) when is_integer(concurrency) do
    for id <- 1..concurrency do
        worker_name = String.to_atom("#{module}_#{id}")
        channel_name = String.to_atom("#{module}_#{id}.Channel")
        %{
          id: worker_name,
          start: {module, :start_link, [[channel_name: channel_name]]},
          restart: :transient
        }
    end
  end

  def start(_type, _args) do    
    children = List.flatten([
      # Start the AMQP connection
      %{
        id: Matchmaking.AMQP.Connection, 
        start: {Matchmaking.AMQP.Connection, :start_link, []},
        restart: :transient
      },
      # Start the middleware and workers
      spawn_workers(Matchmaking.Middleware.Worker, @config[:middleware_workers]),
      spawn_workers(Matchmaking.Generic.Worker, @config[:middleware_workers]),
      spawn_workers(Matchmaking.Requeue.Worker, @config[:requeue_workers]),
    ])

    opts = [strategy: :one_for_one, name: Matchmaking.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
