defmodule Matchmaking.AMQP.Connection do
  use Spotter.AMQP.Connection,
  otp_app: :matchmaking
end
