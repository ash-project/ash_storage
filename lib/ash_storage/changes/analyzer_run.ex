defmodule AshStorage.Changes.AnalyzerRun do
  @moduledoc false
  # Shared analyzer execution for the two attach creation paths,
  # `AshStorage.Changes.Attach` and `AshStorage.Changes.HandleFileArgument`, so
  # their eager/Oban analyzer handling stays in one place and can't drift.

  alias AshStorage.AnalyzerMetadata
  alias AshStorage.AttachmentDefinition

  @doc "Whether any configured analyzer for the attachment runs as an Oban job."
  def has_oban_analyzers?(attachment_def) do
    Enum.any?(attachment_def.analyzers || [], &(&1.analyze == :oban))
  end

  @doc """
  Persist initial analyzer metadata, then run the eager (non-Oban) analyzers.

  Returns `{:ok, blob, attrs_to_write}`, where `attrs_to_write` accumulates any
  `write_attributes` results produced by eager analyzers.

  Options:

    * `:flag_pending_analyzers?` - when `true` and at least one analyzer runs as
      an Oban job, set `pending_analyzers: true` on the blob so the cron-driven
      scheduler can recover it. `Changes.Attach` sets this; `HandleFileArgument`
      triggers `run_pending_analyzers` directly once the parent record exists,
      so it leaves this `false` (the default).

  Scope options (`:actor`, `:tenant`, `:authorize?`, `:tracer`) are threaded
  through the blob updates, and the tenant is embedded in the pending analyzer
  metadata so the Oban writeback can run under the right tenant.
  """
  def run_analyzers(blob, attachment_def, record, io, opts \\ []) do
    analyzer_defs = attachment_def.analyzers || []

    if analyzer_defs == [] do
      {:ok, blob, %{}}
    else
      context_opts = Keyword.take(opts, [:actor, :tenant, :authorize?, :tracer])
      normalized = AttachmentDefinition.normalize_analyzers(analyzer_defs)
      content_type = blob.content_type || "application/octet-stream"
      initial_analyzers = initial_analyzers(normalized, record, attachment_def, context_opts)

      with {:ok, blob} <-
             Ash.update(
               blob,
               update_params(initial_analyzers, normalized, opts),
               Keyword.merge(context_opts, action: :update_metadata)
             ) do
        eager =
          Enum.filter(normalized, fn {module, analyze, _opts, _wa} ->
            analyze != :oban && module.accept?(content_type)
          end)

        run_eager_analyzers(blob, eager, io, context_opts)
      end
    end
  end

  defp update_params(initial_analyzers, normalized, opts) do
    flag_pending? =
      Keyword.get(opts, :flag_pending_analyzers?, false) and
        Enum.any?(normalized, fn {_module, analyze, _opts, _wa} -> analyze == :oban end)

    if flag_pending? do
      %{analyzers: initial_analyzers, pending_analyzers: true}
    else
      %{analyzers: initial_analyzers}
    end
  end

  defp initial_analyzers(normalized, record, attachment_def, context_opts) do
    Map.new(normalized, fn {module, _analyze, opts, write_attributes} ->
      string_opts = Map.new(opts, fn {k, v} -> {to_string(k), v} end)

      entry =
        %{
          "status" => "pending",
          "opts" => string_opts,
          "source" => AnalyzerMetadata.source(record.__struct__, attachment_def)
        }
        |> maybe_put_tenant(context_opts[:tenant])

      entry =
        if write_attributes != [] do
          string_wa = Map.new(write_attributes, fn {k, v} -> {to_string(k), to_string(v)} end)

          entry
          |> Map.put("write_attributes", string_wa)
          |> Map.put(
            "write_target",
            %{
              "resource" => to_string(record.__struct__),
              "id" => to_string(Map.get(record, :id))
            }
            |> maybe_put_tenant(context_opts[:tenant])
          )
        else
          entry
        end

      {to_string(module), entry}
    end)
  end

  defp maybe_put_tenant(map, nil), do: map
  defp maybe_put_tenant(map, tenant), do: Map.put(map, "tenant", tenant)

  defp run_eager_analyzers(blob, [], _io, _context_opts), do: {:ok, blob, %{}}

  defp run_eager_analyzers(blob, eager_analyzers, io, context_opts) do
    {:ok, path} = resolve_analyzer_path(io)

    try do
      Enum.reduce_while(eager_analyzers, {:ok, blob, %{}}, fn {module, _analyze, opts,
                                                               write_attributes},
                                                              {:ok, blob, acc_writes} ->
        analyzer_key = to_string(module)

        {status, metadata_to_merge} =
          case module.analyze(path, opts) do
            {:ok, result} -> {"complete", result}
            {:error, _reason} -> {"error", %{}}
          end

        new_writes =
          if status == "complete" && write_attributes != [] do
            Enum.reduce(write_attributes, %{}, fn {result_key, attr_name}, acc ->
              case Map.fetch(metadata_to_merge, to_string(result_key)) do
                {:ok, value} -> Map.put(acc, attr_name, value)
                :error -> acc
              end
            end)
          else
            %{}
          end

        case Ash.update(
               blob,
               %{
                 analyzer_key: analyzer_key,
                 status: status,
                 metadata_to_merge: metadata_to_merge
               },
               Keyword.merge(context_opts, action: :complete_analysis)
             ) do
          {:ok, blob} -> {:cont, {:ok, blob, Map.merge(acc_writes, new_writes)}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    after
      maybe_cleanup_tempfile(io, path)
    end
  end

  defp resolve_analyzer_path(%Ash.Type.File{} = file) do
    case Ash.Type.File.path(file) do
      {:ok, path} -> {:ok, path}
      _ -> write_tempfile(file)
    end
  end

  defp resolve_analyzer_path(%File.Stream{path: path}), do: {:ok, path}

  defp resolve_analyzer_path(data) when is_binary(data) or is_list(data) do
    write_tempfile(data)
  end

  defp write_tempfile(%Ash.Type.File{} = file) do
    {:ok, device} = Ash.Type.File.open(file, [:read, :binary])
    data = IO.binread(device, :eof)
    File.close(device)
    write_tempfile(data)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_tempfile(data) when is_binary(data) do
    path = Path.join(System.tmp_dir!(), "ash_storage_analyze_#{AshStorage.generate_key()}")
    File.write!(path, data)
    {:ok, path}
  end

  defp write_tempfile(data) when is_list(data) do
    write_tempfile(IO.iodata_to_binary(data))
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp maybe_cleanup_tempfile(%Ash.Type.File{} = file, path) do
    case Ash.Type.File.path(file) do
      {:ok, ^path} -> :ok
      _ -> File.rm(path)
    end
  end

  defp maybe_cleanup_tempfile(%File.Stream{}, _path), do: :ok
  # sobelow_skip ["Traversal.FileModule"]
  defp maybe_cleanup_tempfile(_data, path), do: File.rm(path)
end
