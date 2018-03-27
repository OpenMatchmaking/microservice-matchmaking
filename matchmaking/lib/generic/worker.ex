defmodule Matchmaking.Generic.Worker do
  @moduledoc """
  Worker that sending incoming messages to the generic queue for processing.
  """
  @exchange_request "open-matchmaking.matchmaking.generic-queue.fanout"
  @queue_request "matchmaking.queues.generic"

  use AMQP
  use Matchmaking.AMQP.Worker.Consumer,
  queue: [
    name: @queue_request,
    routing_key: @queue_request,
    durable: true,
    passive: true
  ],
  exchange: [
    name: @exchange_request,
    type: :direct,
    durable: true,
    passive: true
  ],
  qos: [
    prefetch_count: 10
  ]

  @groups Confex.fetch_env!(:matchmaking, RatingGroups)
  @default_rating_group Enum.at(@groups, Integer.floor_div(length(@groups), 2) + 1)

  @default_queue_path "matchmaking.queues"
  @default_exchange_path "open-matchmaking.matchmaking"
  @default_exchange_type "fanout"

  def configure(channel_name, _opts) do
    consumer = create_consumer(channel_name, @queue_request)
    {:ok, [consumer: consumer]}
  end

  def consume(channel_name, tag, headers, payload) do
    data = Poison.decode!(payload)

    player_rating = data["rating"]
    {_rating_from, _rating_to, rating_group_name} = Enum.find(
      @groups, @default_rating_group,
      fn({rating_from, rating_to, _}) ->
        player_rating >= rating_from and player_rating <= rating_to
      end
    )
    queue_forward = "#{@default_queue_path}.#{rating_group_name}"
    exchange_forward = "#{@default_exchange_path}.#{rating_group_name}.#{@default_exchange_type}"

    safe_run(
      channel_name,
      fn(channel) ->
        AMQP.Basic.publish(channel, exchange_forward, queue_forward, payload, Map.to_list(headers))
      end
    )

    ack(channel_name, tag)
  end
end
