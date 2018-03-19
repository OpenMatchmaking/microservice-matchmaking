defmodule Middleware.Worker do
  @moduledoc false
  use AMQP
  use Spotter.Worker

  @exchange_response "open-matchmaking.responses.direct"

  @exchange_request "open-matchmaking.direct"
  @queue_request "matchmaking.games.search"

  @exchange_forward "open-matchmaking.matchmaking.generic-queue.fanout"
  @queue_forward "matchmaking.queues.generic"

  @router Spotter.Router.new([
    {"matchmaking.games.search", ["matchmaking.games.retrieve", "matchmaking.games.update"]},
  ])

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

  defp get_endpoint(path) do
    case Spotter.Router.dispatch(@router, path) do
      endpoint when endpoint != nil -> {:ok, endpoint}
      nil -> {:error, "The requested resource does not exist."}
    end
  end

  defp check_permissions(endpoint, permissions) do 
    case endpoint.__struct__.has_permissions(endpoint, permissions) do
      true -> {:ok, nil}
      false -> {:error, "The user does not have the necessary permissions for a resource."}
    end
  end

  defp consume(channel, tag, headers, payload) do
    extra_headers = Map.get(headers, :headers, [])
    extra_headers = Enum.into(Enum.map(extra_headers, fn({key, _, value}) -> {key, value} end), %{})
    resource_path = Map.get(extra_headers, "microservice_name")
    raw_permissions = Map.get(extra_headers, "permissions", "")
    permissions = String.split(raw_permissions, ";", trim: true)
    reply_to = Map.get(headers, :reply_to)

    with {:ok, endpoint} <- get_endpoint(resource_path),
         {:ok, nil} <- check_permissions(endpoint, permissions) 
    do
      AMQP.Basic.publish(
        channel, @exchange_forward, @queue_forward, payload, 
        content_type: Map.get(headers, :content_type),
        correlation_id: Map.get(headers, :correlation_id),
        headers: Map.to_list(extra_headers),
        reply_to: reply_to,
        persistent: true
      )
    else
      {:error, reason} ->
        response = Poison.encode!(%{"error" => reason})
        AMQP.Basic.publish(
          channel, @exchange_response, reply_to, response, 
          content_type: Map.get(headers, :content_type),
          correlation_id: Map.get(headers, :correlation_id),
          persistent: true
        )
    end

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
