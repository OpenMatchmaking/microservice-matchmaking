defmodule MiddlewareWorkerTest do
  use AMQP
  use ExUnit.Case

  import Mock
  import Spotter.Worker

  alias Matchmaking.AMQP.Connection, as: RabbitMqConnection
  alias Matchmaking.Middleware.Worker, as: MiddlewareWorker
  alias Spotter.Testing.AmqpBlockingClient

  @middleware_exchange "open-matchmaking.direct"
  @middleware_queue "matchmaking.games.search"

  @generic_exchange "open-matchmaking.responses.direct"
  @response_queue_name "client_response_queue"

  @queue_forward "matchmaking.queues.generic"

  @rabbitmq_options [
    username: "user",
    password: "password",
    host: "rabbitmq",
    port: 5672,
    virtual_host: "vhost",
    queue: [
      name: @response_queue_name,
      routing_key: @response_queue_name,
      exclusive: true,
      durable: true,
      passive: false,
      auto_delete: true
    ],
    exchange: [
      name: @generic_exchange,
      type: :direct,
      durable: true,
      passive: true
    ],
    qos: [
      prefetch_count: 10
    ]
  ]

  @client_data %{
    "id" => "507f1f77aabbccd000000000",
    "player_id" => "507f1f77aabbccd000000001",
    "total_games" => 0,
    "wins" => 0,
    "loses" => 0,
    "rating" => 0
  }

  setup_with_mocks([
    {
      MiddlewareWorker,
      [],
      [add_user_to_queue: fn(_user_id) -> {:ok, :added} end,
       get_player_statistics: fn(_channel_name, _user_id) -> {:ok, @client_data} end]
    }
  ]) do
    middleware_worker = start_supervised!(%{
      id: Matchmaking.Middleware.Worker,
      start: {Matchmaking.Middleware.Worker, :start_link, [[channel_name: MiddlewareWorker.Channel]]},
      restart: :transient
    })

    {:ok, rabbitmq_client} = start_supervised({AmqpBlockingClient, @rabbitmq_options})
    AmqpBlockingClient.configure_channel(rabbitmq_client, @rabbitmq_options)

    {:ok, [worker: middleware_worker, client: rabbitmq_client]}
  end

  def cleanup(context) do
    stop_supervised(context[:client])
    stop_supervised(context[:worker])
  end

  test "Middleware pushes the prepared data about the player to the next stage", context do
    message = Poison.encode!(%{"game-mode"  => "team-deathmatch"})

    AmqpBlockingClient.send(
      context[:client],
      message,
      [
        request_exchange: @middleware_exchange,
        request_routing_key: @middleware_queue,
        headers: [
          om_microservice_name: "matchmaking.games.search",
          om_request_url: "api/v1/matchmaking/search",
          om_permissions: "matchmaking.games.retrieve;matchmaking.games.update",
          om_user_id: "507f1f77aabbccd000000000",
        ],
        reply_to: @response_queue_name,
        correlation_id: "test-client"
      ]
    )

    {response, meta} = AmqpBlockingClient.consume(context[:client], @response_queue_name)
    assert response == :empty
    assert meta == nil

    {response_2, _meta_2} = AmqpBlockingClient.consume(context[:client], @queue_forward)
    assert response_2 == message

    cleanup(context)
  end

#  test "Middleware returns an error for non existing endpoint", _context do
#    :ok
#  end
#
#  test "Middleware returns an error for missing permissions", _context do
#    :ok
#  end
#
#  test "Middleware returns an error for the player already in the queue", _context do
#    :ok
#  end
#
#  test "Middleware returns an error for an unsuccessful attempt to get information about the player", _context do
#    :ok
#  end
end
