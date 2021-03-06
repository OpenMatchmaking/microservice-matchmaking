defmodule Matchmaking.AMQP.Worker.Consumer do
  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use Matchmaking.AMQP.Worker,
      otp_app: :matchmaking,
      connection: Matchmaking.AMQP.Connection,
      queue: Keyword.get(opts, :queue, []),
      exchange: Keyword.get(opts, :exchange, []),
      qos: Keyword.get(opts, :qos, [])

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
  end
end
