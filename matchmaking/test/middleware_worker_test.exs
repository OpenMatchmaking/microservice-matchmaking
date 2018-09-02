defmodule MiddlewareWorkerTest do
  use ExUnit.Case

  alias Matchmaking.Middleware.Worker, as: MiddlewareWorker
  import Testing.Helpers.AmqpBlockingClient

  @rabbitmq_options [
    queue: [
      name: "",
      routing_key: "",
      durable: true,
      passive: true,
      exclusive: true,
    ],
    exchange: [
      name: "open-matchmaking.responses.direct",
      type: :direct,
      durable: true,
      passive: true
    ],
    qos: [
      prefetch_count: 10
    ]
  ]

  setup do
#    {:ok, middleware_worker} = start_supervised!(%{
#      id: MiddlewareWorker,
#      start: {MiddlewareWorker, :start_link, [[channel_name: "Middleware.Worker.Test"]]},
#      restart: :transient
#    })
    {:ok, rabbitmq_client} = start_supervised!(Testing.Helpers.AmqpBlockingClient)

    on_exit fn ->
      # GenServer.stop(middleware_worker)
      GenServer.stop(rabbitmq_client)
    end

    #[process: middleware_worker, #
    [client: rabbitmq_client]
  end

  test "Middleware pushes the prepared data about the player to the next stage", _context do

  end

  test "Middleware returns an error for non existing endpoint", _context do

  end

  test "Middleware returns an error for missing permissions", _context do

  end

  test "Middleware returns an error for the player already in the queue", _context do

  end

  test "Middleware returns an error for an unsuccessful attempt to get information about the player", _context do

  end
end
