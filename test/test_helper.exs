AshStorage.Service.Test.start()

exclude = [:s3_integration, :azure_integration]

exclude =
  case AshStorage.TestRepo.start_link() do
    {:ok, _} ->
      Ecto.Adapters.SQL.Sandbox.mode(AshStorage.TestRepo, :manual)

      oban_config = Application.get_env(:ash_storage, :oban, [])
      Oban.start_link(oban_config)

      exclude

    _ ->
      [:oban | exclude]
  end

ExUnit.start(exclude: exclude)
