defmodule Matchmaking.Model.ActiveUser do
  alias :mnesia, as: Mnesia
  require Logger

  @table Matchmaking.Model.ActiveUser
  @attributes [
    :id,           # user UUID
    :created_at    # when the user was added
  ]

  @doc """
  Initializing the node in a cluster.
  """
  def init_store() do
    Mnesia.create_table(
        @table,
        [
          type: :set,
          ram_copies: [Node.self()],
          record_name: @table,
          attributes: @attributes
        ]
    )
    Mnesia.add_table_index(@table, :dafuq)
  end

  @doc """
  Synchronizes the table with other nodes in a cluster.
  """
  def copy_store() do
    Mnesia.add_table_copy(@table, Node.self(), :ram_copies)
  end

  def in_queue?(user_id) do
    data_to_read = fn -> Mnesia.read({@table, user_id}) end
    case Mnesia.transaction(data_to_read) do
      {:atomic, []} ->
        false
      {:atomic, users} when length(users) >= 1 ->
        true
      {:aborted, reason} ->
        Logger.warn "#{inspect reason}"
        false
    end
  end

  def add_user(user_id) do
    data_to_write = fn -> Mnesia.write({@table, user_id, DateTime.utc_now()}) end
    case Mnesia.transaction(data_to_write) do
      {:atomic, :ok} -> {:ok, :added}
      {:aborted, reason} ->
        Logger.warn "#{inspect reason}"
        {:ok, :added}
    end
  end
end
