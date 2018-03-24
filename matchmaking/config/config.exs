# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
use Mix.Config

# This configuration is loaded before any dependency and is restricted
# to this project. If another project depends on this project, this
# file won't be loaded nor affect the parent project. For this reason,
# if you want to provide default values for your application for
# 3rd-party users, it should be done in your "mix.exs" file.

config :matchmaking, Matchmaking.AMQP.Connection,
  username: {:system, "SPOTTER_AMQP_USERNAME", "guest"},
  password: {:system, "SPOTTER_AMQP_PASSWORD", "guest"},
  host: {:system, "SPOTTER_AMQP_HOST", "localhost"},
  port: {:system, "SPOTTER_AMQP_PORT", 5672},
  virtual_host: {:system, "SPOTTER_AMQP_VHOST", "vhost"},
  connection_timeout: {:system, "SPOTTER_AMQP_TIMEOUT", 60_000}
