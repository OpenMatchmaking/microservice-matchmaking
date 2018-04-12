defmodule Matchmaking.Lobby.Worker do
  @moduledoc """
  Worker that sending to each client.
  """
  # TODO: After sending response for each player delete him from the storage with active users (because it's done)
  # TODO: Implement and integrate with the game-server microservice

  @exchange_request "open-matchmaking.matchmaking.lobby.fanout"
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
    type: :fanout,
    durable: true,
    passive: true
  ],
  qos: [
    prefetch_count: 10
  ]

  @exchange_response "open-matchmaking.responses.direct"

  def configure(channel_name, _opts) do
    consumer = create_consumer(channel_name, @queue_request)
    {:ok, [consumer: consumer]}
  end

  defp get_server_credentials() do
    # TODO: Replace the fake response onto a real connection data
    %{
      "ip" => "127.0.0.1",
      "port" => 9001,
      "credentials" => %{
        "token" => "secret_token"
      }
    }
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

  def broadcast_data(channel_name, grouped_players, server_credentials) do
    Enum.map(grouped_players, fn({team, players}) ->
      Enum.map(players, fn(player) ->
        queue_name = player["response-queue"]
        response = Poison.encode!(%{
          "content" => %{
            "ip" => server_credentials["ip"],
            "port": server_credentials["port"],
            "team": team,
            "credentials": server_credentials["credentials"]
          },
          "event-name" => player["event-name"]
        })

        send_response(channel_name, queue_name, response)
        Matchmaking.Model.ActiveUser.remove_user(player["id"])
        {:ok}
      end)

      {team, []}
      end
    )
  end

  def consume(channel_name, tag, _headers, payload) do
    grouped_players = Poison.decode!(payload)
    server_credentials = get_server_credentials()
    spawn fn -> broadcast_data(channel_name, grouped_players, server_credentials) end
    ack(channel_name, tag)
  end
end
