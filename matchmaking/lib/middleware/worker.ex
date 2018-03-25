defmodule Matchmaking.Middleware.Worker do
  @moduledoc false
  @exchange_request "open-matchmaking.direct"
  @queue_request "matchmaking.games.search"

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

  @exchange_response "open-matchmaking.responses.direct"

  @exchange_forward "open-matchmaking.matchmaking.generic-queue.fanout"
  @queue_forward "matchmaking.queues.generic"

  @router Spotter.Router.new([
    {"matchmaking.games.search", ["matchmaking.games.retrieve", "matchmaking.games.update"]},
  ])

  def configure(channel, _config) do
    :ok = AMQP.Exchange.direct(channel, @exchange_forward, durable: true, passive: true)

    {:ok, _} = AMQP.Queue.declare(channel, @queue_forward, durable: true, passive: true)
    :ok = AMQP.Queue.bind(channel, @queue_forward, @exchange_forward, routing_key: @queue_forward)

    create_consumer(channel, @queue_request)
    channel
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

  def consume(_channel, tag, headers, payload) do
    extra_headers = Map.get(headers, :headers, [])
    extra_headers = Enum.into(Enum.map(extra_headers, fn({key, _, value}) -> {key, value} end), %{})
    resource_path = Map.get(extra_headers, "microservice_name")
    raw_permissions = Map.get(extra_headers, "permissions", "")
    permissions = String.split(raw_permissions, ";", trim: true)
    reply_to = Map.get(headers, :reply_to)

    with {:ok, endpoint} <- get_endpoint(resource_path),
         {:ok, nil} <- check_permissions(endpoint, permissions) 
    do
      safe_run fn(channel) ->
        AMQP.Basic.publish(
          channel, @exchange_forward, @queue_forward, payload, 
          content_type: Map.get(headers, :content_type),
          correlation_id: Map.get(headers, :correlation_id),
          headers: Map.to_list(extra_headers),
          reply_to: reply_to,
          persistent: true
        )
      end
    else
      {:error, reason} ->
        response = Poison.encode!(%{"error" => reason})
        safe_run fn(channel) ->
          AMQP.Basic.publish(
            channel, @exchange_response, reply_to, response, 
            content_type: Map.get(headers, :content_type),
            correlation_id: Map.get(headers, :correlation_id),
            persistent: true
          )
        end
    end

    ack(tag)
  end
end
