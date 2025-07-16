defmodule JumpAgent.Repo.Migrations.AddEmbeddingStatusFields do
  use Ecto.Migration

  def change do
    alter table(:document_embeddings) do
      add :embedding_status, :string, default: "pending", null: false
      add :embedding_generated_at, :utc_datetime
      add :embedding_failed_at, :utc_datetime
      add :embedding_error, :text
      add :embedding_retry_count, :integer, default: 0
    end

    create index(:document_embeddings, [:embedding_status])
    create index(:document_embeddings, [:embedding_failed_at])

    execute """
      UPDATE document_embeddings
      SET embedding_status = CASE
        WHEN embedding IS NOT NULL THEN 'complete'
        ELSE 'pending'
      END,
      embedding_generated_at = CASE
        WHEN embedding IS NOT NULL THEN updated_at
        ELSE NULL
      END
    """
  end

  def down do
    alter table(:document_embeddings) do
      remove :embedding_status
      remove :embedding_generated_at
      remove :embedding_failed_at
      remove :embedding_error
      remove :embedding_retry_count
    end
  end
end
