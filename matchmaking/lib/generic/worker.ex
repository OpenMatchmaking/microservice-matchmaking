defmodule Matchmaking.Generic.Worker do
  @moduledoc """
  Worker that sending incoming messages to the certain queue for processing.
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
    type: :fanout,
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

  def generate_queue_name(group_name) do
    "#{@default_queue_path}.#{group_name}"
  end

  def generate_exchange_name(group_name) do
    "#{@default_exchange_path}.#{group_name}.#{@default_exchange_type}"
  end

  def find_rating_group_by_rating(rating) do
    Enum.find(
      @groups, @default_rating_group,
      fn({rating_from, rating_to, _}) ->
        rating >= rating_from and rating <= rating_to
      end
    )
  end

  def consume(channel_name, tag, headers, payload) do
    data = Poison.decode!(payload)
    {_, _, rating_group_name} = find_rating_group_by_rating(data["rating"])
    queue_forward = generate_queue_name(rating_group_name)
    exchange_forward = generate_exchange_name(rating_group_name)

    safe_run(
      channel_name,
      fn(channel) ->
        AMQP.Basic.publish(channel, exchange_forward, queue_forward, payload, Map.to_list(headers))
      end
    )

    ack(channel_name, tag)
  end
end
