defmodule Matchmaking.Middleware.Worker do
  @moduledoc false

  @exchange_request "open-matchmaking.direct"
  @queue_request "matchmaking.games.search"

  require Logger

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

  @exchange_response "open-matchmaking.responses.direct"

  @exchange_player_stats "open-matchmaking.player-stats.statistic.retrieve.direct"
  @queue_player_stats "player-stats.statistic.retrieve"

  @exchange_forward "open-matchmaking.matchmaking.generic-queue.direct"
  @queue_forward "matchmaking.queues.generic"

  @router Spotter.Router.new([
    {"matchmaking.games.search", ["matchmaking.games.retrieve", "matchmaking.games.update"]},
  ])

  def configure(channel_name, _opts) do
    channel = get_channel(channel_name)

    :ok = AMQP.Exchange.direct(channel, @exchange_forward, durable: true, passive: true)

    {:ok, _} = AMQP.Queue.declare(channel, @queue_forward, durable: true, passive: true)
    :ok = AMQP.Queue.bind(channel, @queue_forward, @exchange_forward, routing_key: @queue_forward)

    consumer = create_consumer(channel_name, @queue_request)
    {:ok, [consumer: consumer]}
  end

  def get_endpoint(path) do
    case Spotter.Router.dispatch(@router, path) do
      endpoint when endpoint != nil -> {:ok, endpoint}
      nil -> {:error, "The requested resource does not exist."}
    end
  end

  def check_permissions(endpoint, permissions) do
    case endpoint.__struct__.has_permissions(endpoint, permissions) do
      true -> {:ok, nil}
      false -> {:error, "The user doesn't have the required permissions for a resource."}
    end
  end

  def add_user_to_queue(user_id) do
    case Matchmaking.Model.ActiveUser.in_queue?(user_id) do
      false -> Matchmaking.Model.ActiveUser.add_user(user_id)
      true -> {:error, "You are already in the queue."}
    end
  end

  def get_player_statistics(channel_name, user_id) do
    request_data = Poison.encode!(%{"player_id" => user_id})
    response = send_rpc_request(
      channel_name, request_data,
      [exchange_response: @exchange_response,
       exchange_request: @exchange_player_stats,
       queue_request: @queue_player_stats]
    )

    case Map.has_key?(response, "content") do
      true -> {:ok, response["content"]}
      false ->
        Logger.warn "Received an error from player-statistics microservice: #{inspect response["error"]}. Request data: #{inspect request_data}."
        {:error, "An error occurred while getting a player statistics."}
    end
  end

  def send_request(channel_name, payload, reply_to, headers, extra_headers) do
    safe_run(
      channel_name,
      fn(channel) ->
        AMQP.Basic.publish(
          channel, @exchange_forward, @queue_forward, payload,
          content_type: Map.get(headers, :content_type, "application/json"),
          correlation_id: Map.get(headers, :correlation_id, "null"),
          headers: Map.to_list(extra_headers),
          reply_to: reply_to,
          persistent: true
        )
      end
    )
  end

  def send_response(channel_name, queue_name, errors, headers) do
    response = Poison.encode!(%{
      "errors" => errors,
      "event-name": Map.get(headers, :correlation_id, "null"),
    })
    safe_run(
      channel_name,
      fn(channel) ->
        AMQP.Basic.publish(
          channel, @exchange_response, queue_name, response,
          content_type: Map.get(headers, :content_type, "application/json"),
          persistent: true
        )
      end
    )
  end

  def consume(channel_name, tag, headers, payload) do
    extra_headers = Map.get(headers, :headers, [])
    extra_headers = Enum.into(Enum.map(extra_headers, fn({key, _, value}) -> {key, value} end), %{})
    resource_path = Map.get(extra_headers, "microservice_name")
    raw_permissions = Map.get(extra_headers, "permissions", "")
    permissions = String.split(raw_permissions, ";", trim: true)
    user_id = Map.get(extra_headers, "user_id")
    reply_to = Map.get(headers, :reply_to)
    event_name = Map.get(headers, :correlation_id)

    with {:ok, endpoint} <- get_endpoint(resource_path),
         {:ok, nil} <- check_permissions(endpoint, permissions),
         {:ok, :added} <- add_user_to_queue(user_id),
         {:ok, player_data} <- get_player_statistics(channel_name, user_id)
    do
      request_data = Poison.decode!(payload)
        |> Map.merge(%{
              "id" => user_id,
              "reply_to" => reply_to,
              "event-name" => event_name,
              "detail" => player_data
           })
        |> Poison.encode!

      send_request(channel_name, request_data, reply_to, headers, extra_headers)
    else
      {:error, reason} -> send_response(channel_name, reply_to, reason, headers)
    end

    ack(channel_name, tag)
  end
end
