defmodule Matchmaking.Lobby.Worker do
  @moduledoc """
  Worker that sending to each client.
  """

  @exchange_request "open-matchmaking.matchmaking.lobby.direct"
  @queue_request "matchmaking.queues.lobbies"

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

  @exchange_game_servers_pool "open-matchmaking.direct"
  @queue_game_servers_pool "game-servers-pool.server.retrieve"

  def configure(channel_name, _opts) do
    consumer = create_consumer(channel_name, @queue_request)
    {:ok, [consumer: consumer]}
  end

  defp calculate_required_slots(grouped_players) when is_map(grouped_players) do
    Enum.sum(Enum.map(grouped_players, fn({_team, players}) -> Enum.count(players) end))
  end

  defp get_server_credentials(channel_name, game_server_data) when is_map(game_server_data) do
    request_data = Poison.encode!(game_server_data)
    send_rpc_request(
      channel_name, request_data,
      [exchange_response: @exchange_response,
       exchange_request: @exchange_game_servers_pool,
       queue_request: @queue_game_servers_pool]
    )
  end

  def prepare_response(team, player, server_credentials) do
    Poison.encode!(%{
      "content" => %{
        "ip" => server_credentials["ip"],
        "port" => server_credentials["port"],
        "team" => team,
        "credentials" => server_credentials["credentials"]
      },
      "event-name" => player["event-name"]
    })
  end

  def prepare_error_response(player) do
    Poison.encode!(%{
      "error" => %{
        "type" => "MatchmakingError",
        "details" => "Occurred an unexpected error during instantiating the game server."
      },
      "event-name" => player["event-name"]
    })
  end

  def broadcast_connection_data(channel_name, grouped_players, server_credentials) do
    Enum.map(grouped_players, fn({team, players}) ->
      Enum.map(players, fn(player) ->
        queue_name = player["response-queue"]
        response = prepare_response(team, player, server_credentials)

        send_response(channel_name, queue_name, response)
        Matchmaking.Model.ActiveUser.remove_user(player["id"])
        {:ok}
      end)

      {team, []}
      end
    )
  end

  def broadcast_error(channel_name, grouped_players) do
    Enum.map(grouped_players, fn({team, players}) ->
      Enum.map(players, fn(player) ->
        queue_name = player["response-queue"]
        response = prepare_error_response(player)

        send_response(channel_name, queue_name, response)
        Matchmaking.Model.ActiveUser.remove_user(player["id"])
        {:ok}
      end)

      {team, []}
      end
    )
  end

  defp send_response(channel_name, queue_name, payload) do
    safe_run(
      channel_name,
      fn(channel) ->
        AMQP.Basic.publish(
          channel, @exchange_response, queue_name, payload,
          persistent: true,
          content_type: "application/json"
        )
      end
    )
  end

  def consume(channel_name, tag, _headers, payload) do
    game_lobby_data = Poison.decode!(payload)
    grouped_players = game_lobby_data["teams"] || Map.new()
    server_credentials = get_server_credentials(
      channel_name,
      %{
        "required-slots" => calculate_required_slots(grouped_players),
        "game-mode" => game_lobby_data["game-mode"]
      }
    )

    with true <- is_map(server_credentials),
         false <- Map.has_key?(server_credentials, "error"),
         false <- is_nil(server_credentials["content"])
    do
      broadcast_connection_data(channel_name, grouped_players, server_credentials)
    else
      _ ->
        Logger.warn "Occurred an error when was requested a game server. Details: #{inspect server_credentials}"
        broadcast_error(channel_name, grouped_players)
    end

    ack(channel_name, tag)
  end
end
