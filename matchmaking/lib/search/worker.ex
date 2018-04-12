defmodule Matchmaking.Search.Worker do
  @moduledoc """
  Base module for implementing workers per each rating group.
  """
  # TODO: Save intermidiate state with the grouped players

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
  @default_exchange_type "fanout"
  @default_queue_path "matchmaking.queues"

  @queue_options    [durable: true]
  @exchange_options [type: :fanout, durable: true]
  @qos_options      [prefetch_count: 10]

  @exchange_forward "open-matchmaking.matchmaking.game-lobby.fanout"
  @queue_forward "matchmaking.queues.lobbies"

  @exchange_match_check "open-matchmaking.strategist.check.fanout"
  @queue_match_check "strategist.match.check"

  @exchange_requeue "open-matchmaking.matchmaking.requeue.direct"
  @queue_requeue "matchmaking.games.requeue"

  @exchange_response "open-matchmaking.responses.direct"

  # Client callbacks

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
    {_, opts} = Keyword.pop(opts, :group_name)
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

  # Server callbacks

  def init(opts) do
    {channel_name, updated_opts} = Keyword.pop(opts[:opts], :channel_name, @channel_name)
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
        {:ok, [channel: channel, channel_name: channel_name, meta: custom]}
    end
  end

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

  defp consume(channel_name, tag, headers, payload) do
    player_data = Poison.decode!(payload)

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
        AMQP.Queue.bind(channel, queue_name, @exchange_response, routing_key: queue_name)
      end
    )

    # Send the message to the microservice-strategist
    safe_run(
      channel_name,
      fn(channel) ->
        {game_mode, player} = Map.pop(player_data, "game-mode")

        data = Poison.encode!(%{
          "game-mode" => game_mode,
          "new-player" => player,
          "grouped-players" => %{}
        })

        AMQP.Basic.publish(
          channel, @exchange_match_check, @queue_match_check, data,
          persistent: true,
          reply_to: queue_name,
          content_type: "application/json"
        )
      end
    )

    # TODO: Save the player in the group when is it possible
    data = wait_for_response(channel_name, queue_name)
    if Matchmaking.Model.ActiveUser.in_queue?(player_data["id"]) do
      case data["added"] do
        # Add the player to the game lobby
        true ->
          IO.puts "Add the player to the game lobby"
        # Requeue the player and try to find an another game
        false ->
          safe_run(
            channel_name,
            fn(channel) ->
              message_headers = Map.to_list(headers)
              AMQP.Basic.publish(channel, @exchange_requeue, @queue_requeue, payload, message_headers)
            end
          )
      end
    end

    # TODO: Forward the message to the next stage ONLY when the group is filled
    #safe_run(
    #  channel_name,
    #  fn(channel) ->
    #    AMQP.Basic.publish(
    #      channel, @exchange_forward, @queue_forward, payload,
    #      persistent: true,
    #      content_type: "application/json",
    #    )
    #  end
    #)

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
    tag = Map.get(headers, :delivery_tag)
    spawn fn -> consume(channel_name, tag, headers, payload) end
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
