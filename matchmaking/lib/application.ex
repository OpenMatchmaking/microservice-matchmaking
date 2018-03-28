defmodule Matchmaking.Application do
  @moduledoc false
  use Application

  @config Confex.fetch_env!(:matchmaking, __MODULE__)
  @rating_groups Confex.fetch_env!(:matchmaking, RatingGroups)
  
  defp get_child_spec(module, opts, id \\ nil ) do
    %{
      id: id || module,
      start: {module, :start_link, opts},
      restart: :transient
    }
  end

  # Spawn workers depends of the specified concurrency
  defp spawn_workers(module, concurrency) when is_integer(concurrency) do
    for id <- 1..concurrency do
        worker_name = String.to_atom("#{module}_#{id}")
        channel_name = String.to_atom("#{module}_#{id}.Channel")
        get_child_spec(module, [[channel_name: channel_name]], worker_name)
    end
  end

  # Spawn workers used for searching players by their skill or rating
  defp spawn_search_workers(module, concurrency) do
    get_worker_name = fn(group_name, id) -> String.to_atom("#{module}.#{group_name}_#{id}") end
    get_channel_name = fn(group_name, id) -> String.to_atom("#{module}.#{group_name}_#{id}.Channel") end

    for {_, _, group_name} <- @rating_groups,
                       id  <- 1..concurrency,
    do: get_child_spec(
      module,
      [[
        channel_name: get_channel_name.(group_name, id),
        group_name: group_name
      ]],
      get_worker_name.(group_name, id)
    )
  end

  def start(_type, _args) do
    children = List.flatten([
      # Start the AMQP connection
      get_child_spec(Matchmaking.AMQP.Connection, []),

      # Start the middleware and workers
      spawn_workers(Matchmaking.Middleware.Worker, @config[:middleware_workers]),
      spawn_workers(Matchmaking.Generic.Worker, @config[:generic_queue_workers]),
      spawn_workers(Matchmaking.Requeue.Worker, @config[:requeue_workers]),
      spawn_search_workers(Matchmaking.Search.Worker, @config[:search_queue_workers]),
    ])

    opts = [strategy: :one_for_one, name: Matchmaking.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
