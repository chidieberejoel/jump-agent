defmodule JumpAgent.Workers.EmbeddingMaintenanceWorker do
  use Oban.Worker, queue: :maintenance

  alias JumpAgent.AI
  require Logger

  @impl Oban.Worker
  def perform(_job) do
    # Get documents that need embeddings
    documents = AI.list_documents_needing_embeddings(limit: 100)

    if length(documents) > 0 do
      Logger.info("Found #{length(documents)} documents needing embeddings")

      # Schedule retry jobs
      Enum.each(documents, fn document ->
        %{document_id: document.id}
        |> JumpAgent.Workers.EmbeddingRetryWorker.new()
        |> Oban.insert()
      end)

      Logger.info("Scheduled #{length(documents)} embedding retry jobs")
    end

    # Log statistics
    stats = get_overall_statistics()
    Logger.info("Embedding statistics: #{inspect(stats)}")

    :ok
  end

  defp get_overall_statistics do
    import Ecto.Query
    alias JumpAgent.Repo
    alias JumpAgent.AI.DocumentEmbedding

    DocumentEmbedding
    |> group_by([d], d.embedding_status)
    |> select([d], {d.embedding_status, count(d.id)})
    |> Repo.all()
    |> Enum.into(%{})
  end
end
