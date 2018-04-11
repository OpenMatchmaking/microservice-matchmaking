defmodule Matchmaking.Models.ActiveUser do
  alias :mnesia, as: Mnesia

  @table :active_user
  @attributes [
    :id  # user UUID
  ]

  @doc """
  Initializing the node in a cluster.
  """
  def init_store() do
    Mnesia.create_table(@table, [ram_copies: [Node.self()], attributes: @attributes])
    Mnesia.add_table_index(@table, :id)
  end

  @doc """
  Synchronizes the table with other nodes in a cluster.
  """
  def copy_store() do
    Mnesia.add_table_copy(@table, Node.self(), :ram_copies)
  end
end
