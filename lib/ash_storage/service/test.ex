defmodule AshStorage.Service.Test do
  @moduledoc """
  An in-memory storage service for testing.

  Files are stored in an ETS table scoped by a configurable name, making it
  easy to use in concurrent tests. The table is automatically created on first use.

  ## Usage

  In your test config:

      config :my_app, MyApp.MyResource,
        storage: [service: {AshStorage.Service.Test, []}]

  In your test helper or setup:

      AshStorage.Service.Test.start()

  To reset between tests:

      AshStorage.Service.Test.reset!()

  ## Options

  - `:name` - The name of the ETS table (default: `AshStorage.Service.Test`)
  """

  @behaviour AshStorage.Service

  @default_table __MODULE__

  @doc """
  Start the test service. Creates the ETS table if it doesn't exist.

  Should be called in `test_helper.exs` or test setup.
  """
  def start(opts \\ []) do
    table = Keyword.get(opts, :name, @default_table)

    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set])
    end

    :ok
  end

  @doc """
  Reset the test service, clearing all stored files.
  """
  def reset!(opts \\ []) do
    table = Keyword.get(opts, :name, @default_table)

    if :ets.whereis(table) != :undefined do
      :ets.delete_all_objects(table)
    end

    :ok
  end

  @doc """
  List all keys currently stored in the test service.
  """
  def list_keys(opts \\ []) do
    table = Keyword.get(opts, :name, @default_table)
    ensure_started!(table)

    :ets.tab2list(table)
    |> Enum.map(fn {key, _data} -> key end)
  end

  @impl true
  def upload(key, io, opts) do
    table = Keyword.get(opts, :name, @default_table)
    ensure_started!(table)

    data =
      case io do
        %File.Stream{} = stream -> Enum.into(stream, <<>>, &IO.iodata_to_binary/1)
        data when is_binary(data) -> data
        data when is_list(data) -> IO.iodata_to_binary(data)
      end

    :ets.insert(table, {key, data})
    :ok
  end

  @impl true
  def download(key, opts) do
    table = Keyword.get(opts, :name, @default_table)
    ensure_started!(table)

    case :ets.lookup(table, key) do
      [{^key, data}] -> {:ok, data}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def delete(key) do
    delete(key, [])
  end

  @doc """
  Delete a file from the test store.
  """
  def delete(key, opts) do
    table = Keyword.get(opts, :name, @default_table)
    ensure_started!(table)
    :ets.delete(table, key)
    :ok
  end

  @impl true
  def exists?(key) do
    exists?(key, [])
  end

  @doc """
  Check if a file exists in the test store.
  """
  def exists?(key, opts) do
    table = Keyword.get(opts, :name, @default_table)
    ensure_started!(table)
    :ets.member(table, key)
  end

  @impl true
  def url(key, opts) do
    base_url = Keyword.get(opts, :base_url, "http://test.local/storage")
    "#{base_url}/#{key}"
  end

  @impl true
  def direct_upload_url(key, opts) do
    base_url = Keyword.get(opts, :base_url, "http://test.local/storage")

    {:ok,
     %{
       url: "#{base_url}/direct/#{key}",
       headers: %{"content-type" => Keyword.get(opts, :content_type, "application/octet-stream")}
     }}
  end

  defp ensure_started!(table) do
    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set])
    end
  end
end
