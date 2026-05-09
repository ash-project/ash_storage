defmodule AshStorage.Test.PgBlob do
  @moduledoc false
  use Ash.Resource,
    domain: AshStorage.Test.PgDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStorage.BlobResource, AshOban]

  postgres do
    table "storage_blobs"
    repo(AshStorage.TestRepo)
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
        scheduler_module_name(AshStorage.Test.PgBlob.PurgeBlobScheduler)
        worker_module_name(AshStorage.Test.PgBlob.PurgeBlobWorker)
      end

      trigger :run_pending_variants do
        action :run_pending_variants
        read_action :read
        where expr(pending_variants == true)
        scheduler_cron("* * * * *")
        max_attempts(3)
        scheduler_module_name(AshStorage.Test.PgBlob.RunPendingVariantsScheduler)
        worker_module_name(AshStorage.Test.PgBlob.RunPendingVariantsWorker)
      end

      trigger :run_pending_variant do
        action :run_pending_variant
        read_action :read
        max_attempts(3)
        scheduler_module_name(AshStorage.Test.PgBlob.RunPendingVariantScheduler)
        worker_module_name(AshStorage.Test.PgBlob.RunPendingVariantWorker)
      end
    end
  end

  attributes do
    uuid_primary_key :id
  end
end
