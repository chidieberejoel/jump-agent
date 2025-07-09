defmodule JumpAgent.AI.EmbeddingService do
  @moduledoc """
  Service for generating embeddings using Langchain and OpenAI.
  """

  require Logger

  @embedding_model "text-embedding-3-small"
  @max_tokens 8191

  @doc """
  Generates an embedding vector for the given text using Langchain.
  """
  def generate_embedding(text) when is_binary(text) do
    # Truncate text if too long
    text = truncate_text(text)

    api_key = Application.get_env(:langchain, :openai_api_key)

    if is_nil(api_key) || api_key == "" do
      Logger.warning("OpenAI API key not configured for embeddings")
      {:error, :no_api_key}
    else
      try do
        # Make direct API request to OpenAI using Finch
        headers = [
          {"Authorization", "Bearer #{api_key}"},
          {"Content-Type", "application/json"}
        ]
        
        body = Jason.encode!(%{
          model: @embedding_model,
          input: text
        })

        case Finch.build(:post, "https://api.openai.com/v1/embeddings", headers, body)
             |> Finch.request(JumpAgent.Finch, receive_timeout: 30_000) do
          {:ok, %Finch.Response{status: 200, body: response_body}} ->
            parsed_body = Jason.decode!(response_body)
            embedding = parsed_body["data"] |> List.first() |> Map.get("embedding")
            {:ok, embedding}

          {:ok, %Finch.Response{status: status, body: response_body}} ->
            Logger.error("OpenAI API error (#{status}): #{response_body}")
            {:error, :api_error}

          {:error, error} ->
            Logger.error("OpenAI request failed: #{inspect(error)}")
            {:error, :request_error}
        end
      rescue
        error ->
          Logger.error("OpenAI embedding error: #{inspect(error)}")
          {:error, :embedding_error}
      end
    end
  end

  @doc """
  Generates embeddings for multiple texts in batch using Langchain.
  """
  def generate_embeddings(texts) when is_list(texts) do
    # Truncate texts
    texts = Enum.map(texts, &truncate_text/1)

    api_key = Application.get_env(:langchain, :openai_api_key)

    if is_nil(api_key) || api_key == "" do
      Logger.warning("OpenAI API key not configured for embeddings")
      {:error, :no_api_key}
    else
      try do
        # Make direct API request to OpenAI for batch using Finch
        headers = [
          {"Authorization", "Bearer #{api_key}"},
          {"Content-Type", "application/json"}
        ]
        
        body = Jason.encode!(%{
          model: @embedding_model,
          input: texts
        })

        case Finch.build(:post, "https://api.openai.com/v1/embeddings", headers, body)
             |> Finch.request(JumpAgent.Finch, receive_timeout: 60_000) do
          {:ok, %Finch.Response{status: 200, body: response_body}} ->
            parsed_body = Jason.decode!(response_body)
            embeddings = parsed_body["data"] |> Enum.map(&Map.get(&1, "embedding"))
            {:ok, embeddings}

          {:ok, %Finch.Response{status: status, body: response_body}} ->
            Logger.error("OpenAI API error (#{status}): #{response_body}")
            {:error, :api_error}

          {:error, error} ->
            Logger.error("OpenAI request failed: #{inspect(error)}")
            {:error, :request_error}
        end
      rescue
        error ->
          Logger.error("OpenAI batch embedding error: #{inspect(error)}")
          {:error, :embedding_error}
      end
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

  # Private functions

  defp truncate_text(text) do
    # Simple truncation - in production, you'd want smarter tokenization
    # Langchain may handle this internally, but we'll keep it for safety
    if String.length(text) > @max_tokens * 4 do
      String.slice(text, 0, @max_tokens * 4)
    else
      text
    end
  end
end
