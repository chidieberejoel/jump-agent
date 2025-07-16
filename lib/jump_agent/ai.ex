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
    # Default to lenient mode for backward compatibility
    upsert_document_with_optional_embedding(user, attrs)
  end

  @doc """
  Creates or updates a document with optional embedding (lenient mode).
  Always saves the document, generates embedding if possible.
  """
  def upsert_document_with_optional_embedding(user, attrs) do
    attrs = Map.put(attrs, :user_id, user.id)

    # First, save the document
    with {:ok, document} <- save_document(user, attrs),
         {:ok, updated_document} <- try_generate_embedding(document, attrs) do
      {:ok, updated_document}
    else
      {:embedding_failed, document} ->
        # Document saved successfully, but embedding failed
        schedule_embedding_retry(document)
        {:ok, document}
      {:error, reason} ->
        # Critical failure - document couldn't be saved
        Logger.error("Failed to save document: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Creates or updates a document requiring embedding (strict mode).
  Transaction-based - only saves if embedding succeeds.
  Not needed for now
  """
  def upsert_document_with_required_embedding(user, attrs) do
    attrs = Map.put(attrs, :user_id, user.id)

    Multi.new()
    |> Multi.run(:generate_embedding, fn _repo, _changes ->
      if should_generate_embedding?(attrs) do
        EmbeddingService.generate_embedding(attrs.content)
      else
        {:ok, Map.get(attrs, :embedding)}
      end
    end)
    |> Multi.insert_or_update(:document, fn %{generate_embedding: embedding} ->
      attrs_with_embedding =
        attrs
        |> Map.put(:embedding, embedding)
        |> Map.put(:embedding_status, "complete")
        |> Map.put(:embedding_generated_at, DateTime.utc_now())

      build_document_changeset(user.id, attrs_with_embedding)
    end)
    |> Repo.transaction()
    |> case do
         {:ok, %{document: document}} ->
           {:ok, document}
         {:error, :generate_embedding, reason, _} ->
           Logger.error("Embedding generation failed: #{inspect(reason)}")
           {:error, {:embedding_failed, reason}}
         {:error, operation, reason, _} ->
           {:error, {operation, reason}}
       end
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

  @doc """
  Lists documents that need embedding generation or retry.
  """
  def list_documents_needing_embeddings(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    retry_after = Keyword.get(opts, :retry_after_minutes, 60)

    retry_threshold = DateTime.add(DateTime.utc_now(), -retry_after * 60, :second)

    DocumentEmbedding
    |> where([d], is_nil(d.embedding))
    |> where([d], d.embedding_status in ["pending", "failed"])
    |> where([d],
         d.embedding_status == "pending" or
         (d.embedding_status == "failed" and d.embedding_failed_at < ^retry_threshold)
       )
    |> where([d], d.embedding_retry_count < 5)
    |> order_by([d], asc: d.embedding_retry_count, asc: d.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Manually retry embedding generation for a document.
  """
  def retry_document_embedding(document_id) do
    with %DocumentEmbedding{} = document <- Repo.get(DocumentEmbedding, document_id),
         {:ok, embedding} <- EmbeddingService.generate_embedding(document.content) do
      update_document_with_embedding(document, embedding)
    else
      nil ->
        {:error, :document_not_found}
      {:error, reason} ->
        document = Repo.get!(DocumentEmbedding, document_id)

        if document.embedding_retry_count >= 4 do
          # Mark as permanently failed after 5 attempts
          document
          |> DocumentEmbedding.changeset(%{
            embedding_status: "permanently_failed",
            embedding_error: format_error(reason),
            embedding_failed_at: DateTime.utc_now(),
            embedding_retry_count: document.embedding_retry_count + 1
          })
          |> Repo.update()
        else
          update_document_embedding_failed(document, reason)
          schedule_embedding_retry(document)
          {:error, reason}
        end
    end
  end

  @doc """
  Gets statistics about document embeddings for a user.
  """
  def get_embedding_statistics(user) do
    stats =
      DocumentEmbedding
      |> where([d], d.user_id == ^user.id)
      |> group_by([d], d.embedding_status)
      |> select([d], {d.embedding_status, count(d.id)})
      |> Repo.all()
      |> Enum.into(%{})

    %{
      total: Map.values(stats) |> Enum.sum(),
      complete: Map.get(stats, "complete", 0),
      pending: Map.get(stats, "pending", 0),
      failed: Map.get(stats, "failed", 0),
      permanently_failed: Map.get(stats, "permanently_failed", 0)
    }
  end

  # Private helper functions

  defp save_document(user, attrs) do
    attrs = prepare_document_attrs(attrs)

    build_document_changeset(user.id, attrs)
    |> Repo.insert(
         on_conflict: {:replace_all_except, [:id, :inserted_at]},
         conflict_target: [:user_id, :source_type, :source_id]
       )
  end

  defp prepare_document_attrs(attrs) do
    if should_generate_embedding?(attrs) do
      attrs
      |> Map.put(:embedding_status, "pending")
      |> Map.delete(:embedding) # Don't save nil embedding
    else
      attrs
      |> Map.put(:embedding_status, "complete")
      |> Map.put(:embedding_generated_at, DateTime.utc_now())
    end
  end

  defp should_generate_embedding?(attrs) do
    Map.has_key?(attrs, :content) &&
      !Map.has_key?(attrs, :embedding) &&
      String.trim(attrs.content || "") != ""
  end

  defp try_generate_embedding(document, original_attrs) do
    if should_generate_embedding?(original_attrs) do
      case EmbeddingService.generate_embedding(document.content) do
        {:ok, embedding} ->
          update_document_with_embedding(document, embedding)

        {:error, reason} ->
          Logger.warning("Failed to generate embedding for document #{document.id}: #{inspect(reason)}")
          update_document_embedding_failed(document, reason)
          {:embedding_failed, document}
      end
    else
      {:ok, document}
    end
  end

  defp update_document_with_embedding(document, embedding) do
    document
    |> DocumentEmbedding.changeset(%{
      embedding: embedding,
      embedding_status: "complete",
      embedding_generated_at: DateTime.utc_now(),
      embedding_error: nil,
      embedding_failed_at: nil
    })
    |> Repo.update()
  end

  defp update_document_embedding_failed(document, reason) do
    document
    |> DocumentEmbedding.changeset(%{
      embedding_status: "failed",
      embedding_error: format_error(reason),
      embedding_failed_at: DateTime.utc_now(),
      embedding_retry_count: (document.embedding_retry_count || 0) + 1
    })
    |> Repo.update!()
  end

  defp format_error(reason) do
    case reason do
      {:api_error, message} -> "API Error: #{message}"
      :no_api_key -> "OpenAI API key not configured"
      :rate_limited -> "Rate limit exceeded"
      :timeout -> "Request timeout"
      other -> inspect(other)
    end
    |> String.slice(0, 500) # Limit error message length
  end

  defp build_document_changeset(user_id, attrs) do
    case find_existing_document(user_id, attrs[:source_type], attrs[:source_id]) do
      nil -> %DocumentEmbedding{}
      existing -> existing
    end
    |> DocumentEmbedding.changeset(attrs)
  end

  defp find_existing_document(user_id, source_type, source_id) do
    DocumentEmbedding
    |> where([d], d.user_id == ^user_id)
    |> where([d], d.source_type == ^source_type)
    |> where([d], d.source_id == ^source_id)
    |> Repo.one()
  end

  defp schedule_embedding_retry(document) do
    delay = calculate_retry_delay(document)

    %{document_id: document.id}
    |> JumpAgent.Workers.EmbeddingRetryWorker.new(
         schedule_in: delay,
         max_attempts: 5
       )
    |> Oban.insert()

    Logger.info("Scheduled embedding retry for document #{document.id} in #{delay} seconds")
  end

  defp calculate_retry_delay(document) do
    # Exponential backoff: 1min, 2min, 4min, 8min, 16min
    attempt = document.embedding_retry_count || 1
    base_delay = 60

    min(base_delay * :math.pow(2, attempt - 1), 960) |> round()
  end
end
