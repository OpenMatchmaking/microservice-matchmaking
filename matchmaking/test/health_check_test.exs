defmodule ApiHealthCheckTest do
  use ExUnit.Case
  use Plug.Test

  @opts Matchmaking.Api.Router.init([])

  test "returns OK for healt-check API endpoint" do
    conn = conn(:get, "/matchmaking/api/health-check")
    conn = Matchmaking.Api.Router.call(conn, @opts)

    assert conn.state == :sent
    assert conn.status == 200
    assert conn.resp_body == "OK"
  end
end
