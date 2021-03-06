defmodule Matchmaking.AMQP.Worker do
  @moduledoc """
  Base module for implementing workers of Mathcmaking microservice
  """
  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use AMQP
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
      def configure(_channel_name, _opts) do
        {:ok, []}
      end

      @doc """
      The default implementation for processing a consumed message.
      """
      def consume(channel_name, tag, _headers, _payload) do
        ack(channel_name, tag)
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

      # AMQP wrappers for communicating with microservices

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
        Poison.decode!(payload)
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
      def handle_info({:basic_deliver, payload, headers}, state) do
        channel_name = state[:channel_name]
        tag = Map.get(headers, :delivery_tag)
        spawn fn -> consume(channel_name, tag, headers, payload) end
        {:noreply, state}
      end

      defoverridable [configure: 2, consume: 4]
    end
  end
end
