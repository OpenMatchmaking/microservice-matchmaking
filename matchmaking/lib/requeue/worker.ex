defmodule Requeue.Worker do
  @moduledoc """
  Worker that requeuing incoming messages to the generic queue. 
  """
  use AMQP
  #use Spotter.Worker

  @exchange_request "open-matchmaking.matchmaking.requeue.direct"
  @queue_request "matchmaking.games.requeue"

  @exchange_forward "open-matchmaking.matchmaking.generic-queue.fanout"
  @queue_forward "matchmaking.queues.generic"

  def configure(connection, _config) do
    {:ok, channel} = AMQP.Channel.open(connection)
    :ok = AMQP.Exchange.direct(channel, @exchange_request, durable: true, passive: true)
    :ok = AMQP.Exchange.direct(channel, @exchange_forward, durable: true, passive: true)

    {:ok, queue_request} = AMQP.Queue.declare(channel, @queue_request, durable: true, passive: true)
    :ok = AMQP.Queue.bind(channel, @queue_request, @exchange_request, routing_key: @queue_request)

    {:ok, queue_forward} = AMQP.Queue.declare(channel, @queue_forward, durable: true, passive: true)
    :ok = AMQP.Queue.bind(channel, @queue_forward, @exchange_forward, routing_key: @queue_forward)

    :ok = AMQP.Basic.qos(channel, prefetch_count: 10)
    {:ok, _} = AMQP.Basic.consume(channel, @queue_request)

    {:ok, [channel: channel, queue_request: queue_request, queue_forward: queue_forward]}
  end

  defp consume(channel, tag, headers, payload) do
    AMQP.Basic.publish(channel, @exchange_forward, @queue_forward, payload, Map.to_list(headers))
    AMQP.Basic.ack(channel, tag)
  end

  # Confirmation sent by the broker after registering this process as a consumer
  def handle_info({:basic_consume_ok, %{consumer_tag: _consumer_tag}}, state) do
    {:noreply, state}
  end

  # Sent by the broker when the consumer is unexpectedly cancelled
  def handle_info({:basic_cancel, %{consumer_tag: _consumer_tag}}, state) do
    {:stop, :normal, state}
  end

  # Confirmation sent by the broker to the consumer process after a Basic.cancel
  def handle_info({:basic_cancel_ok, %{consumer_tag: _consumer_tag}}, state) do
    {:noreply, state}
  end

  # Notification about an incoming message
  def handle_info({:basic_deliver, payload, headers}, state) do
    channel = state[:meta][:channel]
    tag = Map.get(headers, :delivery_tag)
    spawn fn -> consume(channel, tag, headers, payload) end
    {:noreply, state}
  end
end
