defmodule JumpAgent.Workers.WebhookRenewalWorker do
  @moduledoc """
  Worker to renew expiring webhooks for Gmail and Calendar.
  """

  use Oban.Worker, queue: :webhooks, max_attempts: 3

  alias JumpAgent.{Accounts, WebhookService}
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "service" => service}}) do
    user = Accounts.get_user!(user_id)

    case service do
      "gmail" ->
        case WebhookService.setup_gmail_webhook(user) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, "Failed to renew Gmail webhook: #{inspect(reason)}"}
        end

      "calendar" ->
        case WebhookService.setup_calendar_webhook(user) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, "Failed to renew Calendar webhook: #{inspect(reason)}"}
        end

      _ ->
        {:error, "Unknown service: #{service}"}
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)
end
