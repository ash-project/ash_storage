defmodule Demo.Blob do
  @moduledoc false
  use Ash.Resource,
    domain: Demo.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStorage.BlobResource, AshOban],
    notifiers: [Demo.BlobNotifier]

  postgres do
    table "storage_blobs"
    repo(Demo.Repo)
  end

  blob do
  end

  oban do
    triggers do
      trigger :purge_blob do
        action :purge_blob
        read_action :read
        where expr(pending_purge == true)
        scheduler_cron("* * * * *")
        max_attempts(3)
        scheduler_module_name(Demo.Blob.PurgeBlobScheduler)
        worker_module_name(Demo.Blob.PurgeBlobWorker)
      end

      trigger :run_pending_variant do
        action :run_pending_variant
        read_action :read
        max_attempts(3)
        scheduler_module_name(Demo.Blob.RunPendingVariantScheduler)
        worker_module_name(Demo.Blob.RunPendingVariantWorker)
      end

      trigger :run_pending_variants do
        action :run_pending_variants
        read_action :read
        max_attempts(3)
        scheduler_module_name(Demo.Blob.RunPendingVariantsScheduler)
        worker_module_name(Demo.Blob.RunPendingVariantsWorker)
      end

      trigger :schedule_pending_variants do
        action :schedule_pending_variants
        read_action :read
        where expr(pending_variants == true)
        scheduler_cron("* * * * *")
        max_attempts(3)
        scheduler_module_name(Demo.Blob.SchedulePendingVariantsScheduler)
        worker_module_name(Demo.Blob.SchedulePendingVariantsWorker)
      end

      trigger :run_pending_analyzers do
        action :run_pending_analyzers
        read_action :read
        where expr(pending_analyzers == true)
        scheduler_cron("* * * * *")
        max_attempts(3)
        scheduler_module_name(Demo.Blob.RunPendingAnalyzersScheduler)
        worker_module_name(Demo.Blob.RunPendingAnalyzersWorker)
      end
    end
  end

  attributes do
    uuid_primary_key :id
  end
end
