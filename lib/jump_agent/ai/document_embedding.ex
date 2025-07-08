defmodule JumpAgent.AI.DocumentEmbedding do
  use JumpAgent.Schema
  alias JumpAgent.Accounts.User
  alias Pgvector.Ecto.Vector

  @valid_source_types ["gmail", "hubspot_contact", "hubspot_note", "calendar"]

  schema "document_embeddings" do
    field :source_type, :string
    field :source_id, :string
    field :content, :string
    field :metadata, :map, default: %{}
    field :embedding, Vector
    field :created_at_source, :utc_datetime

    belongs_to :user, User

    timestamps()
  end

  @doc false
  def changeset(embedding, attrs) do
    embedding
    |> cast(attrs, [:user_id, :source_type, :source_id, :content, :metadata,
      :embedding, :created_at_source])
    |> validate_required([:user_id, :source_type, :source_id, :content])
    |> validate_inclusion(:source_type, @valid_source_types)
    |> validate_length(:content, min: 1, max: 8000) # OpenAI token limit
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :source_type, :source_id])
  end

  def valid_source_types, do: @valid_source_types
end
