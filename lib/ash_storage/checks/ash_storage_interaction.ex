defmodule AshStorage.Checks.AshStorageInteraction do
  @moduledoc """
  A policy check that matches the calls AshStorage makes for itself.

  AshStorage authorizes a file operation at the host resource's action:
  `attach_<name>`, `detach_<name>`, `purge_<name>`, an action with
  `attach_file/2` or `attach_blob/2`, or the host's destroy. The calls the
  library then makes for itself carry the caller's actor, tenant and
  `authorize?`, and the private context `%{ash_storage?: true}`, which this
  check matches. They are:

  - its calls to blob and attachment rows: storing, analyzing, linking,
    replacing and purging a file, generating variants, and the background
    jobs;
  - an analyzer job's write of its `write_attributes` to the host record, the
    host read and the update;
  - on a read that generates a variant on demand for its URL, the create of
    that variant's blob, for whoever reads the host record.

  So the blob and attachment resources can allow the library and deny
  everything else:

      policies do
        bypass AshStorage.Checks.AshStorageInteraction do
          authorize_if always()
        end

        # ... your policies for everyone else
      end

  The marker is never on the caller's call to a host action, nor on a
  reader's relationship loads, and Ash does not pass private context on to
  the actions a marked call runs in turn. A policy that does not ask for it is
  not affected by it.

  `AshStorage.Operations.prepare_direct_upload/3` creates its blob as a
  marked call too, since there is no host action in front of it: authorize
  the caller before you call it.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "AshStorage is performing this interaction"

  @impl true
  def match?(_actor, %{subject: %{context: %{private: %{ash_storage?: true}}}}, _opts),
    do: true

  def match?(_actor, _context, _opts), do: false
end
