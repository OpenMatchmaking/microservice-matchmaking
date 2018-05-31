defmodule Matchmaking.Model.LobbyState do
  alias :mnesia, as: Mnesia

  @rating_groups Confex.fetch_env!(:matchmaking, RatingGroups)
  @table_prefix Matchmaking.Model.LobbyState
  @attributes [
    :id,         # UUID
    :dump,       # Shared state in JSON as string
    :game_mode   # The game mode
  ]

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
          ram_copies: [Node.self()],
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
      Mnesia.add_table_copy(table_name, Node.self(), :ram_copies)
    end
  end

  @doc """
  Returns the name of the table with data based on the
  specified rating group prefix.
  """
  def get_table_name(suffix) do
    table_name = "#{@table_prefix}.#{String.capitalize(suffix)}"
    String.to_atom(table_name)
  end

  @doc """
  Return an empty state for a game lobby.
  """
  def get_an_empty_state() do
    %{}
  end

  @doc """
  Returns a random shared lobby state. If the table is empty returns `nil`.
  """
  def get_state(table_suffix, game_mode, attempt \\ 5, timeout \\ 1_000)
  def get_state(_table_suffix, _game_mode, attempt, _timeout)
    when is_integer(attempt) and attempt <= 0
  do
    {:ok, get_an_empty_state()}
  end

  def get_state(table_suffix, game_mode, attempt, timeout)
      when is_integer(attempt) and attempt > 0 and
           is_integer(timeout) and timeout > 0
  do
    table_name = get_table_name(table_suffix)
    data_to_read = fn ->
      result = Mnesia.select(
        table_name,
        [{
          {table_name, :"$1", :"$2", :"$3"},
          [{:==, :"$3", game_mode}],
          [:"$$"]
        }],
        1,
        :sticky_write
      )

      case result do
        {records, _} ->
          [id, state_dump, _game_mode] = List.first(records)
          Mnesia.delete(table_name, id, :sticky_write)
          {:existing_state, state_dump}
        :"$end_of_table" ->
          {:not_found, nil}
      end
    end

    case Mnesia.transaction(data_to_read) do
      {:atomic, {:existing_state, state_dump}} ->
        {:ok, Poison.decode!(state_dump)}
      {:atomic, {:not_found, nil}} ->
        {:ok, get_an_empty_state()}
      {:aborted, _reason} ->
        :timer.sleep(timeout)
        get_state(table_suffix, game_mode, attempt - 1, timeout)
    end
  end

  @doc """
  Inserts or updates a state in database by UUID.
  """
  def update_state(table_suffix, game_mode, state, attempt \\ 5, timeout \\ 1_000)
  def update_state(_table_suffix, _game_mode, _state, attempt, _timeout)
      when is_integer(attempt) and attempt <= 0
  do
    {:error, :mnesia_not_responding}
  end

  def update_state(table_suffix, game_mode, state, attempt, timeout)
    when is_integer(attempt) and attempt > 0 and
         is_integer(timeout) and timeout > 0
  do
    table_name = get_table_name(table_suffix)
    id = UUID.uuid4()
    state_dump = Poison.encode!(state)
    data_to_write = fn -> Mnesia.write({table_name, id, state_dump, game_mode}) end
    case Mnesia.transaction(data_to_write) do
      {:atomic, :ok} ->
        {:ok, :updated}
      {:aborted, _reason} ->
        :timer.sleep(timeout)
        update_state(table_suffix, game_mode, state, attempt - 1, timeout)
    end
  end
end
