defmodule JumpAgent.AI.EmbeddingService do
  @moduledoc """
  Service for generating embeddings using OpenAI.
  """

  require Logger

  @embedding_model "text-embedding-3-small"
  @max_tokens 8191

  @doc """
  Generates an embedding vector for the given text.
  """
  def generate_embedding(text) when is_binary(text) do
    # Truncate text if too long
    text = truncate_text(text)

    # Check if the OpenAI client is available
    if GenServer.whereis(JumpAgent.AI.OpenAIClient) do
      try do
        JumpAgent.AI.OpenAIClient.create_embedding(text)
      catch
        :exit, {:noproc, _} ->
          Logger.warning("OpenAI client is not running")
          {:error, :openai_client_not_available}
        :exit, reason ->
          Logger.error("Failed to call OpenAI client: #{inspect(reason)}")
          {:error, :openai_client_error}
      end
    else
      Logger.warning("OpenAI client is not started")
      {:error, :openai_client_not_started}
    end
  end

  @doc """
  Generates embeddings for multiple texts in batch.
  """
  def generate_embeddings(texts) when is_list(texts) do
    # OpenAI supports batch embedding
    texts = Enum.map(texts, &truncate_text/1)

    if GenServer.whereis(JumpAgent.AI.OpenAIClient) do
      try do
        JumpAgent.AI.OpenAIClient.create_embeddings(texts)
      catch
        :exit, {:noproc, _} ->
          Logger.warning("OpenAI client is not running")
          {:error, :openai_client_not_available}
        :exit, reason ->
          Logger.error("Failed to call OpenAI client: #{inspect(reason)}")
          {:error, :openai_client_error}
      end
    else
      Logger.warning("OpenAI client is not started")
      {:error, :openai_client_not_started}
    end
  end

  defp truncate_text(text) do
    # Simple truncation - in production, you'd want smarter tokenization
    if String.length(text) > @max_tokens * 4 do
      String.slice(text, 0, @max_tokens * 4)
    else
      text
    end
  end

  @doc """
  Prepares text content for embedding by cleaning and formatting.
  """
  def prepare_content(content, metadata \\ %{}) do
    # Add metadata to content for better context
    metadata_str =
      metadata
      |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)
      |> Enum.join(", ")

    if metadata_str != "" do
      "[#{metadata_str}] #{content}"
    else
      content
    end
  end
end
