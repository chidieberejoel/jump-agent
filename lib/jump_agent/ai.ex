defmodule JumpAgent.AI do
  @moduledoc """
  The AI context for managing conversations, messages, and agent interactions.
  """

  import Ecto.Query, warn: false
  alias JumpAgent.Repo
  alias JumpAgent.AI.{Conversation, Message, Task, Instruction, DocumentEmbedding}
  alias JumpAgent.AI.{Agent, EmbeddingService, VectorSearch}
  require Logger

  # Conversations

  @doc """
  Creates a new conversation for a user.
  """
  def create_conversation(user, attrs \\ %{}) do
    attrs = Map.put(attrs, :user_id, user.id)

    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets a conversation by ID for a user.
  """
  def get_conversation!(user, id) do
#    Repo.get_by!(Conversation, id: id, user_id: user.id)
    Conversation
    |> where([c], c.id == ^id and c.user_id == ^user.id)
    |> Repo.one!()
  end

  @doc """
  Lists conversations for a user, ordered by last message.
  """
  def list_conversations(user, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Conversation
    |> where([c], c.user_id == ^user.id)
    |> where([c], c.is_active == true)
    |> order_by([c], desc: c.last_message_at, desc: c.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Updates a conversation.
  """
  def update_conversation(conversation, attrs) do
    conversation
    |> Conversation.changeset(attrs)
    |> Repo.update()
  end

  # Messages

  @doc """
  Creates a message in a conversation.
  """
  def create_message(conversation, attrs) do
    attrs =
      attrs
      |> Map.put(:conversation_id, conversation.id)
      |> Map.put(:user_id, conversation.user_id)

    result =
      %Message{}
      |> Message.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, message} ->
        # Update conversation's last_message_at
        update_conversation(conversation, %{last_message_at: message.inserted_at})
        {:ok, message}
      error ->
        error
    end
  end

  @doc """
  Lists messages in a conversation.
  """
  def list_messages(conversation, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Message
    |> where([m], m.conversation_id == ^conversation.id)
    |> order_by([m], asc: m.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # Tasks

  @doc """
  Creates a task for the AI agent to execute.
  """
  def create_task(user, attrs) do
    attrs = Map.put(attrs, :user_id, user.id)

    %Task{}
    |> Task.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a task.
  """
  def update_task(task, attrs) do
    task
    |> Task.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Gets pending tasks for a user.
  """
  def get_pending_tasks(user) do
    Task
    |> where([t], t.user_id == ^user.id)
    |> where([t], t.status in ["pending", "in_progress", "waiting"])
    |> where([t], is_nil(t.scheduled_at) or t.scheduled_at <= ^DateTime.utc_now())
    |> order_by([t], asc: t.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a task by ID.
  """
  def get_task!(id) do
    Repo.get!(Task, id)
  end

  # Instructions

  @doc """
  Creates an ongoing instruction for the user.
  Note: user_id should already be in attrs
  """
  def create_instruction(user, attrs) do
    # Don't add user_id here - it should already be in attrs from the form
    %Instruction{}
    |> Instruction.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets active instructions for a user by trigger type.
  """
  def get_active_instructions(user, trigger_type \\ nil) do
    query =
      Instruction
      |> where([i], i.user_id == ^user.id)
      |> where([i], i.is_active == true)
      |> where([i], is_nil(i.expires_at) or i.expires_at > ^DateTime.utc_now())

    query =
      if trigger_type do
        where(query, [i], i.trigger_type == ^trigger_type)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Lists all instructions for a user.
  """
  def list_instructions(user) do
    Instruction
    |> where([i], i.user_id == ^user.id)
    |> order_by([i], desc: i.inserted_at)
    |> Repo.all()
  end

  @doc """
  Updates an instruction.
  """
  def update_instruction(instruction, attrs) do
    instruction
    |> Instruction.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deactivates an instruction.
  """
  def deactivate_instruction(instruction) do
    update_instruction(instruction, %{is_active: false})
  end

  # Document Embeddings

  @doc """
  Creates or updates a document embedding using Langchain.
  """
  def upsert_document_embedding(user, attrs) do
    attrs = Map.put(attrs, :user_id, user.id)

    # Generate embedding if content is provided but embedding is not
    attrs =
      if Map.has_key?(attrs, :content) && !Map.has_key?(attrs, :embedding) do
        # Use Langchain's embedding service
        case EmbeddingService.generate_embedding(attrs.content) do
          {:ok, embedding} -> Map.put(attrs, :embedding, embedding)
          {:error, reason} ->
            Logger.warning("Failed to generate embedding for document: #{inspect(reason)}")
            # Continue without embedding - the document will be saved but won't be searchable
            attrs
        end
      else
        attrs
      end

    %DocumentEmbedding{}
    |> DocumentEmbedding.changeset(attrs)
    |> Repo.insert(
         on_conflict: {:replace_all_except, [:id, :inserted_at]},
         conflict_target: [:user_id, :source_type, :source_id]
       )
  end

  @doc """
  Searches for similar documents using vector similarity.
  """
  def search_similar_documents(user, query_text, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    threshold = Keyword.get(opts, :threshold, 0.2)  # Changed from 0.7 to 0.2
    source_types = Keyword.get(opts, :source_types, nil)

    try do
      case EmbeddingService.generate_embedding(query_text) do
        {:ok, query_embedding} ->
          VectorSearch.search_documents(user.id, query_embedding, limit, threshold, source_types)
        {:error, :no_api_key} ->
          Logger.warning("Embeddings disabled: OpenAI API key not configured")
          []
        {:error, reason} ->
          Logger.error("Failed to generate query embedding: #{inspect(reason)}")
          []
      end
    catch
      :exit, {:noproc, _} ->
        Logger.warning("OpenAI client not available for embeddings")
        []
      :exit, reason ->
        Logger.error("Embedding generation crashed: #{inspect(reason)}")
        []
    end
  end

  @doc """
  Processes a user message through the AI agent.
  """
  def process_user_message(conversation, message_content) do
    # This will be called by the LiveView to process messages
    Agent.process_message(conversation, message_content)
  end

  @doc """
  Processes an event from an external system (Gmail, Calendar, HubSpot).
  """
  def process_external_event(user, event_type, event_data) do
    # Check for matching instructions
    instructions = get_active_instructions(user, event_type)

    # Process each matching instruction
    Enum.each(instructions, fn instruction ->
      Agent.process_instruction_trigger(user, instruction, event_data)
    end)
  end

  @doc """
  Gets recent context for a conversation.
  """
  def get_conversation_context(conversation, opts \\ []) do
    # Get recent messages
    messages = list_messages(conversation, limit: Keyword.get(opts, :message_limit, 10))

    # Get any active tasks
    tasks =
      Task
      |> where([t], t.conversation_id == ^conversation.id)
      |> where([t], t.status in ["pending", "in_progress", "waiting"])
      |> Repo.all()

    %{
      conversation: conversation,
      messages: messages,
      active_tasks: tasks,
      user_id: conversation.user_id
    }
  end
end
