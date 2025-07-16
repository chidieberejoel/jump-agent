defmodule JumpAgent.Workers.EmbeddingRetryWorker do
  use Oban.Worker,
      queue: :embeddings,
      max_attempts: 5,
      priority: 3

  alias JumpAgent.AI
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"document_id" => document_id}, attempt: attempt}) do
    Logger.info("Retrying embedding for document #{document_id} (attempt #{attempt})")

    case AI.retry_document_embedding(document_id) do
      {:ok, document} ->
        Logger.info("Successfully generated embedding for document #{document_id}")
        :ok

      {:error, :document_not_found} ->
        Logger.error("Document #{document_id} not found")
        :ok # Don't retry if document doesn't exist

      {:error, reason} ->
        Logger.error("Failed to generate embedding for document #{document_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
