defmodule Matchmaking.Api.Router do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/matchmaking/api/health-check" do
    send_resp(conn, 200, "OK")
  end

  match _ do
    send_resp(conn, 404, "Requested API not found.")
  end
end
