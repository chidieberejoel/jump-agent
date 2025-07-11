defmodule JumpAgent.Workers.WebhookMaintenanceWorker do
  @moduledoc """
  Periodic worker to check and renew expiring webhooks.
  """

  use Oban.Worker,
      queue: :maintenance,
      max_attempts: 3

  alias JumpAgent.WebhookService
  require Logger

  @impl Oban.Worker
  def perform(_job) do
    Logger.info("Running webhook maintenance check")

    # Renew any webhooks expiring in the next 24 hours
    WebhookService.renew_expiring_webhooks()

    :ok
  end
end
