defmodule Matchmaking.Search.Worker do
  @moduledoc """
  Base module for implementing workers per each rating group.
  """
  # TODO: Integrate with Python interpreter
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

  @exchange_forward "open-matchmaking.matchmaking.lobby.fanout"
  @queue_forward "matchmaking.queues.lobbies"

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

  defp consume(channel_name, tag, headers, payload) do
    data = Poison.decode!(payload)

    safe_run(
      channel_name,
      fn(channel) ->
        AMQP.Basic.publish(channel, @exchange_forward, @queue_forward, payload, Map.to_list(headers))
      end
    )

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
  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, state) do
    Process.demonitor(monitor_ref)
    channel_name = state[:channel_name]
    config = channel_config(channel_name)
    new_consumer = create_consumer(channel_name, config[:queue][:name])
    Keyword.put(state[:meta], :consumer, new_consumer)
    {:noreply, state}
  end
end
