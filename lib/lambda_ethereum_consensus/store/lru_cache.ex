defmodule LambdaEthereumConsensus.Store.LRUCache do
  @moduledoc """
  Generic cache, used in `LambdaEthereumConsensus.Store.Blocks`
  and `LambdaEthereumConsensus.Store.BlockStates`.
  """
  use GenServer
  require Logger

  @default_max_entries 512
  @default_batch_prune_size 32
  @default_opts [
    max_entries: @default_max_entries,
    batch_prune_size: @default_batch_prune_size
  ]

  @type key() :: any()
  @type value() :: any()
  @type opts() :: [
          {:table, atom()}
          | {:max_entries, non_neg_integer()}
          | {:batch_prune_size, non_neg_integer()}
          | {:store_func, (key(), value() -> any())}
        ]

  ##########################
  ### Public API
  ##########################

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :table)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec put(atom(), key(), value()) :: :ok
  def put(table, key, value) do
    GenServer.call(table, {:put, key, value})
    :ok
  end

  @spec get(atom(), key(), (key() -> value() | nil)) :: value() | nil
  def get(table, key, fetch_func) do
    case :ets.lookup_element(table, key, 2, nil) do
      nil ->
        # Cache miss.
        case fetch_func.(key) do
          nil ->
            nil

          value ->
            GenServer.call(table, {:cache_value, key, value})
            value
        end

      v ->
        :ok = GenServer.cast(table, {:touch_entry, key})
        v
    end
  end

  ##########################
  ### GenServer Callbacks
  ##########################

  @impl GenServer
  def init(opts) do
    data_table = Keyword.fetch!(opts, :table)
    ttl_table = :"#{data_table}_ttl_data"
    _store_func = Keyword.fetch!(opts, :store_func)

    opts =
      Keyword.merge(@default_opts, opts)
      |> Keyword.take([:max_entries, :batch_prune_size, :store_func])
      |> Map.new()

    :ets.new(ttl_table, [
      :ordered_set,
      :private,
      :named_table,
      read_concurrency: false,
      write_concurrency: false,
      decentralized_counters: false
    ])

    :ets.new(data_table, [:set, :public, :named_table])

    state = %{data_table: data_table, ttl_table: ttl_table}
    {:ok, Map.merge(state, opts)}
  end

  @impl GenServer
  def handle_call({:put, key, value}, _from, %{store_func: store} = state) do
    store.(key, value)

    cache_value(state, key, value)

    touch_entry(key, state)

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:cache_value, key, value}, _from, state) do
    cache_value(state, key, value)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast({:touch_entry, key}, state) do
    touch_entry(key, state)
    {:noreply, state}
  end

  ##########################
  ### Private Functions
  ##########################

  defp touch_entry(key, state) do
    update_ttl(state[:data_table], state[:ttl_table], key)
    prune_cache(state)
  end

  defp cache_value(state, key, value) do
    :ets.insert(state.data_table, {key, value, nil})
    touch_entry(key, state)
  end

  defp update_ttl(data_table, ttl_table, key) do
    delete_ttl(data_table, ttl_table, key)
    uniq = :erlang.unique_integer([:monotonic])
    :ets.insert_new(ttl_table, {uniq, key})
    :ets.update_element(data_table, key, {3, uniq})
  end

  defp delete_ttl(data_table, ttl_table, key) do
    case :ets.lookup_element(data_table, key, 3, nil) do
      nil -> nil
      uniq -> :ets.delete(ttl_table, uniq)
    end
  end

  defp prune_cache(%{
         data_table: data_table,
         ttl_table: ttl_table,
         max_entries: max_entries,
         batch_prune_size: batch_prune_size
       }) do
    to_prune = :ets.info(data_table, :size) - max_entries

    if to_prune > 0 do
      {elems, _cont} = :ets.select(ttl_table, [{:_, [], [:"$_"]}], to_prune + batch_prune_size)

      elems
      |> Enum.each(fn {uniq, root} ->
        :ets.delete(ttl_table, uniq)
        :ets.delete(data_table, root)
      end)
    end
  end
end
