defmodule AshStorage.Pipeline.Analysis do
  @moduledoc false
  # Analyzers: the entries a blob's `analyzers` map holds for them, running
  # one analyzer on a local file, recording its outcome, and writing its
  # `write_attributes` back to the host record. The attach paths and the
  # background job all go through here.

  require Logger

  alias AshStorage.Pipeline.{Owner, Scope, Source, Target}

  @max_error_length 500

  @doc """
  Writes a `"pending"` entry for each analyzer of the target's attachment, and
  sets `pending_analyzers` when one of them runs in the background. A no-op
  for an attachment without analyzers.
  """
  @spec init(struct(), Target.t(), Scope.t(), struct()) :: {:ok, struct()} | {:error, term()}
  def init(blob, %Target{} = target, %Scope{} = scope, record) do
    case analyzers(target) do
      [] ->
        {:ok, blob}

      analyzers ->
        entries = Map.new(analyzers, &entry(&1, target, scope, record))

        params =
          if Enum.any?(analyzers, fn {_, analyze, _, _} -> analyze == :oban end),
            do: %{analyzers: entries, pending_analyzers: true},
            else: %{analyzers: entries}

        Ash.update(blob, params, Scope.to_opts(scope, action: :update_metadata))
    end
  end

  @doc """
  Runs the eager analyzers that accept the blob's content type on `source`,
  and returns the blob with their outcomes and the host attributes their
  `write_attributes` map to.
  """
  @spec run_eager(struct(), Source.t(), Target.t(), Scope.t()) ::
          {:ok, struct(), map()} | {:error, term()}
  def run_eager(blob, %Source{} = source, %Target{} = target, %Scope{} = scope) do
    content_type = blob.content_type || "application/octet-stream"

    case Enum.filter(analyzers(target), fn {module, analyze, _, _} ->
           analyze != :oban && module.accept?(content_type)
         end) do
      [] ->
        {:ok, blob, %{}}

      eager ->
        Source.with_local_path(source, fn path ->
          Enum.reduce_while(eager, {:ok, blob, %{}}, fn {module, _, opts, write_attributes},
                                                        {:ok, blob, writes} ->
            outcome = execute(module, path, opts)

            case complete(blob, to_string(module), outcome, scope) do
              {:ok, blob} ->
                {:cont, {:ok, blob, Map.merge(writes, host_writes(outcome, write_attributes))}}

              {:error, _} = error ->
                {:halt, error}
            end
          end)
        end)
    end
  end

  @doc "Runs one analyzer on a local file."
  @spec execute(module(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(module, path, opts) do
    case module.analyze(path, opts) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Records an analyzer's outcome on the blob through its `:complete_analysis`
  action: `{:ok, metadata}`, `{:error, reason}`, or `:skipped` for an
  analyzer that does not accept the blob's content type. A failure keeps its
  reason on the entry as text and logs a warning; it does not fail the
  attach or the job.
  """
  @spec complete(struct(), String.t(), {:ok, map()} | {:error, term()} | :skipped, Scope.t()) ::
          {:ok, struct()} | {:error, term()}
  def complete(blob, analyzer_key, outcome, %Scope{} = scope) do
    params =
      case outcome do
        {:ok, result} ->
          %{status: "complete", metadata_to_merge: result}

        {:error, reason} ->
          Logger.warning("AshStorage analyzer #{analyzer_key} failed on blob #{blob.id}")
          %{status: "error", metadata_to_merge: %{}, error: error_text(reason)}

        :skipped ->
          %{status: "skipped", metadata_to_merge: %{}}
      end

    Ash.update(
      blob,
      Map.put(params, :analyzer_key, analyzer_key),
      Scope.to_opts(scope, action: :complete_analysis)
    )
  end

  defp error_text(reason) when is_binary(reason), do: String.slice(reason, 0, @max_error_length)
  defp error_text(reason), do: reason |> inspect() |> String.slice(0, @max_error_length)

  @doc """
  Runs one pending analyzer on a stored blob: downloads the file, records the
  outcome and writes the analyzer's `write_attributes` to the host record.
  This is what the background job does for each pending analyzer.
  """
  @spec run_pending(struct(), module(), keyword()) :: {:ok, struct()} | {:error, term()}
  def run_pending(blob, analyzer_module, opts) do
    analyzer_key = to_string(analyzer_module)

    case Map.fetch(blob.analyzers || %{}, analyzer_key) do
      {:ok, entry} ->
        scope = opts |> Scope.from_opts() |> Scope.put_new_tenant(entry["tenant"])

        if analyzer_module.accept?(blob.content_type || "application/octet-stream") do
          with {:ok, data} <- AshStorage.Operations.download(blob, opts) do
            outcome =
              Source.with_local_path(Source.new(data), fn path ->
                execute(analyzer_module, path, keyword_opts(entry["opts"] || %{}))
              end)

            with {:ok, blob} <- complete(blob, analyzer_key, outcome, scope) do
              with {:ok, result} <- outcome, do: write_back(entry, result, scope)
              {:ok, blob}
            end
          end
        else
          complete(blob, analyzer_key, :skipped, scope)
        end

      :error ->
        {:error, :analyzer_not_configured}
    end
  end

  @doc """
  Gives every entry that has `write_attributes` but no record to write them
  to the host record's write target. A create does not know the record's key
  before the action has run. A no-op when no entry is missing one.
  """
  @spec bind_write_target(struct(), Target.t(), struct(), Scope.t()) ::
          {:ok, struct()} | {:error, term()}
  def bind_write_target(blob, %Target{} = target, record, %Scope{} = scope) do
    analyzers = blob.analyzers || %{}

    unbound? = fn entry ->
      Map.has_key?(entry, "write_attributes") and
        get_in(entry, ["write_target", "id"]) in [nil, ""]
    end

    if Enum.any?(analyzers, fn {_key, entry} -> unbound?.(entry) end) do
      write_target = write_target(target, record, scope)

      analyzers =
        Map.new(analyzers, fn {key, entry} ->
          if unbound?.(entry),
            do: {key, Map.put(entry, "write_target", write_target)},
            else: {key, entry}
        end)

      Ash.update(blob, %{analyzers: analyzers}, Scope.to_opts(scope, action: :update_metadata))
    else
      {:ok, blob}
    end
  end

  defp analyzers(%Target{attachment: attachment}) do
    AshStorage.AttachmentDefinition.normalize_analyzers(attachment.analyzers || [])
  end

  defp entry({module, _analyze, opts, write_attributes}, target, scope, record) do
    entry =
      %{"status" => "pending", "opts" => Map.new(opts, fn {k, v} -> {to_string(k), v} end)}
      |> put_tenant(scope.tenant)

    entry =
      if write_attributes == [] do
        entry
      else
        entry
        |> Map.put(
          "write_attributes",
          Map.new(write_attributes, fn {k, v} -> {to_string(k), to_string(v)} end)
        )
        |> Map.put("write_target", write_target(target, record, scope))
      end

    {to_string(module), entry}
  end

  defp write_target(target, record, scope) do
    target |> Owner.write_target(record) |> put_tenant(scope.tenant)
  end

  defp put_tenant(map, nil), do: map
  defp put_tenant(map, tenant), do: Map.put(map, "tenant", tenant)

  defp host_writes({:ok, result}, write_attributes) do
    Enum.reduce(write_attributes, %{}, fn {result_key, attribute}, acc ->
      case Map.fetch(result, to_string(result_key)) do
        {:ok, value} -> Map.put(acc, attribute, value)
        :error -> acc
      end
    end)
  end

  defp host_writes(_outcome, _write_attributes), do: %{}

  # sobelow_skip ["DOS.BinToAtom"]
  defp keyword_opts(opts), do: Enum.map(opts, fn {k, v} -> {String.to_existing_atom(k), v} end)

  # sobelow_skip ["DOS.BinToAtom"]
  defp write_back(entry, result, scope) do
    write_attributes = entry["write_attributes"]
    write_target = entry["write_target"]

    if write_attributes && write_target && map_size(write_attributes) > 0 do
      resource = String.to_existing_atom(write_target["resource"])
      opts = scope |> Scope.put_new_tenant(write_target["tenant"]) |> Scope.to_opts()

      attrs =
        Enum.reduce(write_attributes, %{}, fn {result_key, attr_name}, acc ->
          case Map.fetch(result, result_key) do
            {:ok, value} -> Map.put(acc, String.to_existing_atom(attr_name), value)
            :error -> acc
          end
        end)

      if map_size(attrs) > 0 do
        case Ash.get(resource, write_target["id"], opts) do
          {:ok, record} ->
            record
            |> Ash.Changeset.for_update(:update, %{})
            |> Ash.Changeset.force_change_attributes(attrs)
            |> Ash.update(opts)

          _ ->
            :ok
        end
      end
    end
  end
end
