defmodule JumpAgent.Repo.Migrations.CreateAiAgentSchema do
  use Ecto.Migration

  def change do
    # Conversations/Threads
    create table(:ai_conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :title, :string
      add :context, :map, default: %{}
      add :is_active, :boolean, default: true
      add :last_message_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:ai_conversations, [:user_id])
    create index(:ai_conversations, [:last_message_at])

    # Messages
    create table(:ai_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :conversation_id, references(:ai_conversations, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false # "user", "assistant", "system"
      add :content, :text, null: false
      add :metadata, :map, default: %{}
      add :tool_calls, {:array, :map}, default: []
      add :tool_call_id, :string

      timestamps(type: :utc_datetime)
    end

    create index(:ai_messages, [:conversation_id])
    create index(:ai_messages, [:user_id])

    # Tasks
    create table(:ai_tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :conversation_id, references(:ai_conversations, type: :binary_id, on_delete: :nilify_all)
      add :message_id, references(:ai_messages, type: :binary_id, on_delete: :nilify_all)
      add :type, :string, null: false # "schedule_meeting", "send_email", etc.
      add :status, :string, null: false, default: "pending" # pending, in_progress, waiting, completed, failed
      add :parameters, :map, default: %{}
      add :context, :map, default: %{}
      add :result, :map
      add :error, :text
      add :attempts, :integer, default: 0
      add :scheduled_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:ai_tasks, [:user_id])
    create index(:ai_tasks, [:status])
    create index(:ai_tasks, [:scheduled_at])
    create index(:ai_tasks, [:type])

    # Agent Memory/Instructions
    create table(:ai_instructions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :instruction_type, :string, null: false # "ongoing", "temporary"
      add :trigger_type, :string # "email_received", "calendar_event_created", etc.
      add :instruction, :text, null: false
      add :conditions, :map, default: %{}
      add :actions, {:array, :map}, default: []
      add :is_active, :boolean, default: true
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:ai_instructions, [:user_id, :is_active])
    create index(:ai_instructions, [:trigger_type])

    # Document Embeddings for RAG
    create table(:document_embeddings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :source_type, :string, null: false # "gmail", "hubspot_contact", "hubspot_note", "calendar"
      add :source_id, :string, null: false # External ID from the source system
      add :content, :text, null: false
      add :metadata, :map, default: %{}
      add :embedding, :vector, size: 1536 # OpenAI embeddings are 1536 dimensions
      add :created_at_source, :utc_datetime

      timestamps(type: :utc_datetime)
    end

#    TODO; Revert
    create index(:document_embeddings, [:user_id, :source_type])
#    create unique_index(:document_embeddings, [:user_id, :source_type, :source_id])

    # Create a custom index for vector similarity search
    execute """
            CREATE INDEX document_embeddings_embedding_idx ON document_embeddings
            USING ivfflat (embedding vector_cosine_ops)
            WITH (lists = 100)
            """, "DROP INDEX document_embeddings_embedding_idx"

    # Tool Execution Log
    create table(:ai_tool_executions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:ai_tasks, type: :binary_id, on_delete: :delete_all), null: false
      add :tool_name, :string, null: false
      add :input, :map, default: %{}
      add :output, :map
      add :error, :text
      add :duration_ms, :integer
      add :executed_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:ai_tool_executions, [:task_id])
    create index(:ai_tool_executions, [:tool_name])
  end
end
