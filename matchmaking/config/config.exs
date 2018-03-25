# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
use Mix.Config

# This configuration is loaded before any dependency and is restricted
# to this project. If another project depends on this project, this
# file won't be loaded nor affect the parent project. For this reason,
# if you want to provide default values for your application for
# 3rd-party users, it should be done in your "mix.exs" file.

config :matchmaking, Matchmaking.Application,
  # Concurrency settings
  middleware_workers: {:system, :integer, "MIDDLEWARE_WORKERS", 1},
  generic_queue_workers: {:system, :integer, "GENERIC_QUEUE_WORKERS", 1},
  search_queue_workers: {:system, :integer, "SEARCH_QUEUE_WORKERS", 1},
  requeue_workers: {:system, :integer, "REQUEUE_WORKERS", 1},
  game_lobby_workers: {:system, :integer, "GAME_LOBBY_WORKERS", 1},
  # Rating groups
  groups: [
    {0,    1499, "bronze"},
    {1500, 1999, "silver"},
    {2000, 2499, "gold"},
    {2500, 2999, "platinum"},
    {3000, 3499, "diamond"},
    {3500, 3999, "master"},
    {4000, 5000, "grandmaster"},
  ]

config :matchmaking, Matchmaking.AMQP.Connection,
  username: {:system, "SPOTTER_AMQP_USERNAME", "guest"},
  password: {:system, "SPOTTER_AMQP_PASSWORD", "guest"},
  host: {:system, "SPOTTER_AMQP_HOST", "localhost"},
  port: {:system, "SPOTTER_AMQP_PORT", 5672},
  virtual_host: {:system, "SPOTTER_AMQP_VHOST", "vhost"},
  connection_timeout: {:system, "SPOTTER_AMQP_TIMEOUT", 60_000}
