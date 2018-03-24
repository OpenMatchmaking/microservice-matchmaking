defmodule Requeue.Worker do
  @moduledoc """
  Worker that requeuing incoming messages to the generic queue. 
  """
  @exchange_request "open-matchmaking.matchmaking.requeue.direct"
  @queue_request "matchmaking.games.requeue"

  use AMQP
  use Matchmaking.Worker.Consumer,
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

  @exchange_forward "open-matchmaking.matchmaking.generic-queue.fanout"
  @queue_forward "matchmaking.queues.generic"

  def configure(channel, _config) do
    :ok = AMQP.Exchange.direct(channel, @exchange_forward, durable: true, passive: true)

    {:ok, _} = AMQP.Queue.declare(channel, @queue_forward, durable: true, passive: true)
    :ok = AMQP.Queue.bind(channel, @queue_forward, @exchange_forward, routing_key: @queue_forward)

    create_consumer(channel, @queue_request)
    channel
  end

  def consume(_channel, tag, headers, payload) do
    safe_run fn(channel) ->
      AMQP.Basic.publish(channel, @exchange_forward, @queue_forward, payload, Map.to_list(headers))
    end
    ack(tag)
  end
end
