defmodule Matchmaking.Worker.Consumer do
  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use Matchmaking.Worker,
      otp_app: :matchmaking,
      connection: Matchmaking.AMQP.Connection,
      queue: Keyword.get(opts, :queue, []),
      exchange: Keyword.get(opts, :exchange, []),
      qos: Keyword.get(opts, :qos, [])

      @doc """
      Creates a consumer and starting monitoring the process.
      """
      def create_consumer(channel, queue_name) do
        safe_run fn(chan) ->
          {:ok, _} = AMQP.Basic.consume(chan, queue_name)
          Process.monitor(chan.pid)
        end
      end

      # Notifies when the process will down for consumer
      def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
        Process.demonitor(monitor_ref)
        new_consumer = create_consumer(nil, channel_config()[:queue][:name])
        Keyword.put(state[:meta], :consumer, new_consumer)
        {:noreply, state}
      end
    end
  end
end
