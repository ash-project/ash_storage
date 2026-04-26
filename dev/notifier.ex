defmodule Demo.BlobNotifier do
  @moduledoc false
  use Ash.Notifier

    if Code.ensure_loaded?(Phoenix.PubSub) do
      @impl true
      def notify(%Ash.Notifier.Notification{action: %{name: :run_pending_analyzers}} = notification) do
          Phoenix.PubSub.broadcast(
            Demo.PubSub,
            "blob_analysis",
            {:analysis_complete, notification.data}
          )
      end
    end

  def notify(_), do: :ok
end
