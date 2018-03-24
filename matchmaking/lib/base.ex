defmodule Matchmaking.Worker do
  @moduledoc """
  Base module for implementing workers of Mathcmaking microservice
  """
  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use Spotter.Worker,
      otp_app: :matchmaking,
      connection: Matchmaking.AMQP.Connection,
      queue: Keyword.get(opts, :queue, []),
      exchange: Keyword.get(opts, :exchange, []),
      qos: Keyword.get(opts, :qos, [])

      unless opts[:queue] do
        raise "You need to configure queue in #{__MODULE__} options."
      end

      unless opts[:queue][:name] do
        raise "You need to configure queue[:name] in #{__MODULE__} options."
      end

      # Client callbacks

      @doc """
      The default implementation for configuring a worker
      """
      def configure(channel, _opts) do
        channel
      end

      @doc """
      The default implementation for processing a consumed message.
      """
      def consume(_channel, tag, _headers, _payload) do
        ack(tag)
      end

      @doc """
      Sents a positive acknowledgement for the message
      """
      def ack(tag) do
        safe_run fn(channel) -> AMQP.Basic.ack(channel, tag) end
      end

      @doc """
      Sents a negative acknowledgement for the message
      """
      def nack(tag) do
        safe_run fn(channel) -> AMQP.Basic.nack(channel, tag) end
      end

      # Server callbacks

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
      def handle_info({:basic_deliver, payload, headers}, channel) do
        tag = Map.get(headers, :delivery_tag)
        spawn fn -> consume(channel, tag, headers, payload) end
        {:noreply, channel}
      end

      defoverridable [configure: 2, consume: 4]
    end
  end
end
