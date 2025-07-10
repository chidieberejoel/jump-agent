defmodule JumpAgent.AI.VectorSearch do
  @moduledoc """
  Handles vector similarity search using pgvector.
  """

  import Ecto.Query
  alias JumpAgent.Repo
  alias JumpAgent.AI.DocumentEmbedding

  @doc """
  Searches for similar documents using cosine similarity.
  """
  def search_documents(user_id, query_embedding, limit \\ 10, threshold \\ 0.7, source_types \\ nil) do
    # Ensure the embedding is a list of floats
    embedding_list =
      case query_embedding do
        %Pgvector{} = vec -> Pgvector.to_list(vec)
        list when is_list(list) -> list
        _ -> raise ArgumentError, "Invalid embedding format"
      end

    # Convert to string format for PostgreSQL
    embedding_string = "[#{Enum.join(embedding_list, ",")}]"

    base_query =
      from d in DocumentEmbedding,
           where: d.user_id == ^user_id,
           select: %{
             id: d.id,
             source_type: d.source_type,
             source_id: d.source_id,
             content: d.content,
             metadata: d.metadata,
             created_at_source: d.created_at_source,
             similarity: fragment("1 - (? <=> ?::vector)", d.embedding, ^embedding_string)
           }

    query =
      if source_types do
        where(base_query, [d], d.source_type in ^source_types)
      else
        base_query
      end

    query
    |> where([d], fragment("1 - (? <=> ?::vector)", d.embedding, ^embedding_string) >= ^threshold)
    |> order_by([d], desc: fragment("1 - (? <=> ?::vector)", d.embedding, ^embedding_string))
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Finds exact matches by source.
  """
  def find_by_source(user_id, source_type, source_id) do
    DocumentEmbedding
    |> where([d], d.user_id == ^user_id)
    |> where([d], d.source_type == ^source_type)
    |> where([d], d.source_id == ^source_id)
    |> Repo.one()
  end

  @doc """
  Bulk upserts document embeddings.
  """
  def bulk_upsert_embeddings(user_id, documents) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      Enum.map(documents, fn doc ->
        # Ensure embedding is in the correct format
        embedding_vector =
          case doc.embedding do
            list when is_list(list) ->
              # Convert list to Pgvector - just pass the list directly
              list
            %Pgvector{} = vec ->
              # Already a Pgvector, convert to list
              Pgvector.to_list(vec)
            _ ->
              raise ArgumentError, "Invalid embedding format for document"
          end

        %{
          id: Ecto.UUID.generate(),
          user_id: user_id,
          source_type: doc.source_type,
          source_id: doc.source_id,
          content: doc.content,
          metadata: doc.metadata || %{},
          embedding: embedding_vector,  # Pass the list directly
          created_at_source: doc.created_at_source || timestamp,
          inserted_at: timestamp,
          updated_at: timestamp
        }
      end)

    Repo.insert_all(
      DocumentEmbedding,
      entries,
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:user_id, :source_type, :source_id]
    )
  end

  @doc """
  Deletes embeddings by source.
  """
  def delete_by_source(user_id, source_type, source_ids) when is_list(source_ids) do
    DocumentEmbedding
    |> where([d], d.user_id == ^user_id)
    |> where([d], d.source_type == ^source_type)
    |> where([d], d.source_id in ^source_ids)
    |> Repo.delete_all()
  end

  @doc """
  Gets document statistics for a user.
  """
  def get_user_statistics(user_id) do
    DocumentEmbedding
    |> where([d], d.user_id == ^user_id)
    |> group_by([d], d.source_type)
    |> select([d], {d.source_type, count(d.id)})
    |> Repo.all()
    |> Enum.into(%{})
  end
end
