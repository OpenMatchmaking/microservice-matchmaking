defmodule Matchmaking.Search.Worker do
  @moduledoc """
  Base module for implementing workers per each rating group.
  """

  @doc """
  Create a link to worker process. Used in supervisors.
  """
  @callback start_link :: Supervisor.on_start

  @doc """
  Get queue status.
  """
  @callback status :: {:ok, %{consumer_count: integer, message_count: integer, queue: String.t()}} | {:error, String.t()}

  use AMQP
  use GenServer
  require Logger

  @connection Matchmaking.AMQP.Connection
  @channel_name String.to_atom("#{__MODULE__}.Channel")

  @default_exchange_path "open-matchmaking.matchmaking"
  @default_exchange_type "direct"
  @default_queue_path "matchmaking.queues"

  @queue_options    [durable: true]
  @exchange_options [type: :direct, durable: true]
  @qos_options      [prefetch_count: 10]

  @exchange_forward "open-matchmaking.matchmaking.game-lobby.direct"
  @queue_forward "matchmaking.queues.lobbies"

  @exchange_match_check "open-matchmaking.strategist.check.direct"
  @queue_match_check "strategist.match.check"

  @exchange_requeue "open-matchmaking.matchmaking.requeue.direct"
  @queue_requeue "matchmaking.games.requeue"

  @exchange_response "open-matchmaking.responses.direct"

  # --------------------------------------------------
  # Client callbacks
  # --------------------------------------------------

  defp generate_queue_name(suffix) do
    "#{@default_queue_path}.#{suffix}"
  end

  defp generate_exchange_name(suffix) do
    "#{@default_exchange_path}.#{suffix}.#{@default_exchange_type}"
  end

  defp prepare_config(opts) do
    unless opts[:group_name] do
      raise "You need to configure group_name in options."
    end

    queue_name = generate_queue_name(opts[:group_name])
    exchange_name = generate_exchange_name(opts[:group_name])
    [
      queue: Keyword.merge([name: queue_name, routing_key: queue_name], @queue_options),
      exchange: Keyword.merge([name: exchange_name], @exchange_options),
      qos: Keyword.merge([], @qos_options)
    ]
  end

  def start_link(opts) do
    config = prepare_config(opts)
    GenServer.start_link(__MODULE__, %{config: config, opts: opts})
  end

  def configure(channel_name, opts) do
    consumer = create_consumer(channel_name, opts[:queue][:name])
    {:ok, [consumer: consumer]}
  end

  @doc """
  Sents a positive acknowledgement for the message
  """
  def ack(channel_name, tag) do
    safe_run(channel_name, fn(channel) -> AMQP.Basic.ack(channel, tag) end)
  end

  @doc """
  Sents a negative acknowledgement for the message
  """
  def nack(channel_name, tag) do
    safe_run(channel_name, fn(channel) -> AMQP.Basic.nack(channel, tag) end)
  end

  @doc """
  Creates a consumer and starting monitoring the process.
  """
  def create_consumer(channel_name, queue_name) do
    safe_run(
      channel_name,
      fn(channel) ->
        {:ok, _} = AMQP.Basic.consume(channel, queue_name)
        Process.monitor(channel.pid)
      end
    )
  end

  @doc """
  Returns a chanel instance by its name.
  """
  def get_channel(channel_name) do
    @connection.get_channel(channel_name)
  end

  @doc """
  Returns a queue status which is linked with the channel.
  """
  def status() do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Returns a channel configuration.
  """
  def channel_config(channel_name) do
    Spotter.AMQP.Connection.Channel.get_config(channel_name)
  end

  @doc """
  Safely executing a function, which is using the channel by its name.
  """
  def safe_run(channel_name, fun) do
    channel = get_channel(channel_name)

    case !is_nil(channel) && Process.alive?(channel.pid) do
      true ->
        fun.(channel)
      _ ->
        Logger.warn("[GenQueue] Channel #{inspect channel} is dead, waiting till it gets restarted")
        :timer.sleep(3_000)
        safe_run(channel_name, fun)
    end
  end

  # --------------------------------------------------
  # AMQP wrappers for RPC requests to microservices
  # --------------------------------------------------

  defp receive_message(channel_name, queue_name) do
    safe_run(
      channel_name,
      fn(channel) ->
        case AMQP.Basic.get(channel, queue_name) do
          {:ok, message, meta} ->
            {message, meta}
          {:empty, _} ->
            :timer.sleep(1000)
            receive_message(channel_name, queue_name)
        end
      end
    )
  end

  defp wait_for_response(channel_name, queue_name) do
    {payload, meta} = receive_message(channel_name, queue_name)
    ack(channel_name, meta.delivery_tag)
    safe_run(channel_name, fn(channel) -> AMQP.Queue.delete(channel, queue_name) end)
    Poison.decode!(payload)["content"]
  end

  defp declare_unique_queue(channel_name, exchange_response) do
    {:ok, queue_name} = safe_run(
      channel_name,
      fn(channel) ->
         {:ok, response_queue} = AMQP.Queue.declare(channel, "", durable: true, exclusive: true)
         {:ok, response_queue.queue}
      end
    )
    :ok = safe_run(
      channel_name,
      fn(channel) ->
        AMQP.Queue.bind(channel, queue_name, exchange_response, routing_key: queue_name)
      end
    )
    queue_name
  end

  def send_request_to_microservice(channel_name, queue_name, data, options \\ []) do
    exchange_request = Keyword.get(options, :exchange_request, "")
    queue_request = Keyword.get(options, :queue_request, "")

    safe_run(
      channel_name,
      fn(channel) ->
        AMQP.Basic.publish(
          channel, exchange_request, queue_request, data,
          persistent: true,
          reply_to: queue_name,
          content_type: "application/json"
        )
      end
    )
    :ok
  end

  def send_rpc_request(channel_name, data, options \\ []) do
    exchange_response = Keyword.get(options, :exchange_response, "")
    exchange_request = Keyword.get(options, :exchange_request, "")
    queue_request = Keyword.get(options, :queue_request, "")

    queue_name = declare_unique_queue(channel_name, exchange_response)
    send_request_to_microservice(
      channel_name, queue_name, data,
      [exchange_request: exchange_request, queue_request: queue_request]
    )
    wait_for_response(channel_name, queue_name)
  end

  # --------------------------------------------------
  # Server callbacks
  # --------------------------------------------------

  def init(opts) do
    {channel_name, updated_opts} = Keyword.pop(opts[:opts], :channel_name, @channel_name)
    {group_name, updated_opts} = Keyword.pop(updated_opts, :group_name)
    opts = Map.put(opts, :opts, updated_opts)

    case Process.whereis(@connection) do
      nil ->
        # Connection doesn't exist, lets fail to recover later
        {:error, :noconn}
      _ ->
        @connection.spawn_channel(channel_name)
        @connection.configure_channel(channel_name, opts[:config])

        channel = get_channel(channel_name)
        {:ok, custom} = configure(channel_name, opts[:config])
        {:ok, [channel: channel, channel_name: channel_name, group_name: group_name, meta: custom]}
    end
  end

  defp requeue_player(channel_name, exchange_requeue, queue_requeue, payload, headers) do
    :timer.sleep(1_000)
    safe_run(
      channel_name,
      fn(channel) ->
        message_headers = Map.to_list(headers)
        AMQP.Basic.publish(channel, exchange_requeue, queue_requeue, payload, message_headers)
      end
    )
  end

  defp prepare_game_lobby(channel_name, exchange_forward, queue_forward, payload) do
    safe_run(
      channel_name,
      fn(channel) ->
        AMQP.Basic.publish(
          channel, exchange_forward, queue_forward, payload,
          persistent: true,
          content_type: "application/json"
        )
      end
    )
  end

  defp get_players_count(teams) do
    Enum.reduce(Map.values(teams), 0, fn(players, acc) -> Enum.count(players) + acc end)
  end

  defp remove_inactive_players(teams) do
    updated_teams = Map.new(
      for team <- Map.keys(teams),
      do: {team, Enum.filter(
             teams[team],
             fn(player) -> Matchmaking.Model.ActiveUser.in_queue?(player["id"]) end)
          }
    )

    players_count_before = get_players_count(teams)
    players_count_after = get_players_count(updated_teams)
    is_changed = players_count_before != players_count_after
    {updated_teams, is_changed}
  end

  defp save_new_state(group_name, game_mode, grouped_players) do
    case Matchmaking.Model.LobbyState.update_state(group_name, game_mode, grouped_players) do
      {:ok, :updated} -> {:ok, :updated}
      {:error, :mnesia_not_responding} ->
        Logger.warn "Occurred an error when trying to save a new game lobby state in Mnesia."
        Matchmaking.Model.LobbyState.update_state(group_name, game_mode, grouped_players, 100, 5_000)
    end
  end

  defp consume(channel_name, group_name, tag, headers, payload) do
    player_data = Poison.decode!(payload)

    {game_mode, player} = Map.pop(player_data, "game-mode")
    {:ok, grouped_players} = Matchmaking.Model.LobbyState.get_state(group_name, game_mode)
    request_data = Poison.encode!(%{
      "game-mode" => game_mode,
      "new-player" => player,
      "grouped-players" => grouped_players
    })
    data = send_rpc_request(
      channel_name, request_data,
      [exchange_response: @exchange_response,
       exchange_request: @exchange_match_check,
       exchange_queue: @queue_match_check]
    )

    if Matchmaking.Model.ActiveUser.in_queue?(player_data["id"]) && !data["added"] do
      requeue_player(channel_name, @exchange_requeue, @queue_requeue, payload, headers)
    end

    {updated_grouped_players, is_changed} = remove_inactive_players(data["grouped-players"])
    case data["is_filled"] && !is_changed do
      true ->
        game_lobby_data = Poison.encode!(%{
          "teams" => updated_grouped_players,
          "game-mode" => game_mode
        })
        prepare_game_lobby(channel_name, @exchange_forward, @queue_forward, game_lobby_data)
      false -> save_new_state(group_name, game_mode, updated_grouped_players)
    end

    ack(channel_name, tag)
  end

  def handle_call(:status, _from, state) do
    safe_run(
      state[:channel],
      fn(channel) ->
        config = channel_config(state[:channel_name])
        {:reply, AMQP.Queue.status(channel, config[:queue][:name]), state}
      end
    )
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
    channel_name = state[:channel_name]
    group_name = state[:group_name]
    tag = Map.get(headers, :delivery_tag)
    spawn fn -> consume(channel_name, group_name, tag, headers, payload) end
    {:noreply, state}
  end

  # Notifies when the process will down for consumer
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    Process.demonitor(monitor_ref)
    channel_name = state[:channel_name]
    config = channel_config(channel_name)
    new_consumer = create_consumer(channel_name, config[:queue][:name])
    Keyword.put(state[:meta], :consumer, new_consumer)
    {:noreply, state}
  end
end
