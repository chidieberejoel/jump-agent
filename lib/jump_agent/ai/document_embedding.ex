defmodule JumpAgent.AI.DocumentEmbedding do
  use JumpAgent.Schema
  alias JumpAgent.Accounts.User
  alias Pgvector.Ecto.Vector

  @valid_source_types ["gmail", "hubspot_contact", "hubspot_note", "calendar"]
  @valid_statuses ["pending", "complete", "failed", "permanently_failed"]

  schema "document_embeddings" do
    field :source_type, :string
    field :source_id, :string
    field :content, :string
    field :metadata, :map, default: %{}
    field :embedding, Vector
    field :created_at_source, :utc_datetime

    # Embedding status tracking
    field :embedding_status, :string, default: "pending"
    field :embedding_generated_at, :utc_datetime
    field :embedding_failed_at, :utc_datetime
    field :embedding_error, :string
    field :embedding_retry_count, :integer, default: 0

    belongs_to :user, User

    timestamps()
  end

  @doc false
  def changeset(embedding, attrs) do
    embedding
    |> cast(attrs, [
      :user_id, :source_type, :source_id, :content, :metadata,
      :embedding, :created_at_source, :embedding_status,
      :embedding_generated_at, :embedding_failed_at,
      :embedding_error, :embedding_retry_count
    ])
    |> validate_required([:user_id, :source_type, :source_id, :content])
    |> validate_inclusion(:source_type, @valid_source_types)
    |> validate_inclusion(:embedding_status, @valid_statuses)
    |> validate_length(:content, min: 1, max: 8000) # OpenAI token limit
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :source_type, :source_id])
  end

  def valid_source_types, do: @valid_source_types
  def valid_statuses, do: @valid_statuses
end
