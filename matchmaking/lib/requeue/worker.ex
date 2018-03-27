defmodule Matchmaking.Requeue.Worker do
  @moduledoc """
  Worker that requeuing incoming messages to the generic queue. 
  """
  @exchange_request "open-matchmaking.matchmaking.requeue.direct"
  @queue_request "matchmaking.games.requeue"

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

  @exchange_forward "open-matchmaking.matchmaking.generic-queue.fanout"
  @queue_forward "matchmaking.queues.generic"

  def configure(channel, _opts) do
    :ok = AMQP.Exchange.direct(channel, @exchange_forward, durable: true, passive: true)

    {:ok, _} = AMQP.Queue.declare(channel, @queue_forward, durable: true, passive: true)
    :ok = AMQP.Queue.bind(channel, @queue_forward, @exchange_forward, routing_key: @queue_forward)

    consumer = create_consumer(channel, @queue_request)
    {:ok, [consumer: consumer]}
  end

  def consume(channel, tag, headers, payload) do
    safe_run(
      channel,
      fn(channel) ->
        message_headers = Map.to_list(headers)
        AMQP.Basic.publish(channel, @exchange_forward, @queue_forward, payload, message_headers)
      end
    )
    ack(channel, tag)
  end
end
