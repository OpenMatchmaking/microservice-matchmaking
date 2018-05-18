defmodule Matchmaking.Model.LobbyState do
  alias :mnesia, as: Mnesia
  require Logger

  @rating_groups Confex.fetch_env!(:matchmaking, RatingGroups)
  @table_prefix Matchmaking.Model.LobbyState
  @attributes [
    :id,        # UUID
    :dump       # Shared state in JSON as string
  ]

  @doc """
  Returns the name of the table with data based on the
  specified rating group prefix.
  """
  def get_table_name(suffix) do
    table_name = "#{@table_prefix}.#{String.capitalize(suffix)}"
    String.to_atom(table_name)
  end

  @doc """
  Initializing the node in a cluster.
  """
  def init_store() do
    for {_, _, group_name} <- @rating_groups
    do
      table_name = get_table_name(group_name)
      Mnesia.create_table(
        table_name,
        [
          type: :set,
          disc_copies: [Node.self()],
          record_name: table_name,
          attributes: @attributes
        ]
      )
    end
  end

  @doc """
  Synchronizes the table with other nodes in a cluster.
  """
  def copy_store() do
    for {_, _, group_name} <- @rating_groups
    do
      table_name = get_table_name(group_name)
      Mnesia.add_table_copy(table_name, Node.self(), :disc_copies)
    end
  end

  def get_state(table_suffix, attempt \\ 5, timeout \\ 1_000) do
    table_name = get_table_name(table_suffix)
    table_size = Mnesia.table_info(table_name, :size)
    case table_size > 0 do
      true ->
        data_to_read = fn ->
          Mnesia.lock({:table, table_name}, :sticky_write)
          key = Mnesia.first(table_name)
          record = Mnesia.read(table_name, key, :sticky_write)
          Mnesia.delete(table_name, key, :sticky_write)
          record
        end
        case Mnesia.transaction(data_to_read) do
          {:atomic, []} ->
            {:ok, nil}
          {:atomic, records} ->
            {table_name, id, state_dump} = List.first(records)
            {:ok, {id, Poison.decode!(state_dump)}}
          {:aborted, reason} ->
            Logger.warn "#{inspect reason}, attempt=#{attempt}. Retry in #{timeout} milliseconds."
            :timer.sleep(timeout)

            case attempt > 0 do
              true -> get_state(table_suffix, attempt - 1, timeout)
              false -> {:ok, nil}
            end
        end
      false ->
        {:ok, nil}
    end
  end

  @doc """
  Inserts or updates a state in database by UUID.
  """
  def update_state(table_suffix, row_id, state, attempt \\ 5, timeout \\ 1_000) do
    table_name = get_table_name(table_suffix)
    state_dump = Poison.encode!(state)
    data_to_write = fn -> Mnesia.write({table_name, row_id, state_dump}) end
    case Mnesia.transaction(data_to_write) do
      {:atomic, :ok} ->
        {:ok, :updated}
      {:aborted, reason} ->
        Logger.warn "#{inspect reason}, attempt=#{attempt}. Retry in #{timeout} milliseconds."
        :timer.sleep(timeout)

        case attempt > 0 do
          true -> update_state(table_suffix, row_id, state, attempt - 1, timeout)
          false -> {:ok, :updated}
        end
    end
  end
end
