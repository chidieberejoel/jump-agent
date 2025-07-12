defmodule JumpAgent.AI.LangchainService do
  @moduledoc """
  Main AI service using Langchain for LLM interactions, embeddings, and tool execution.
  """

  alias LangChain.ChatModels.ChatOpenAI
  alias LangChain.Message
  alias LangChain.Function
  alias LangChain.Chains.LLMChain
  alias LangChain.VectorStores.Ecto
  alias JumpAgent.AI.VectorSearch
  alias JumpAgent.AI.Tools
  alias JumpAgent.Accounts.User
  require Logger

  # Use gpt-4.1-mini-2025-04-14 as default, but allow configuration via environment variable
  @default_model "gpt-4.1-mini-2025-04-14"
  @temperature 0.7
  @max_tokens 1000

  @system_prompt """
  You are an intelligent assistant for financial advisors and communications.
  You have access to the user's Gmail, Google Calendar, and HubSpot CRM.

  Your capabilities include:
  - Searching through emails and CRM data to answer questions
  - Scheduling meetings and managing calendar events
  - Sending emails on behalf of the user
  - Creating and updating contacts in HubSpot
  - Adding notes to HubSpot contacts
  - Following ongoing instructions set by the user

  Always be helpful, concise, and proactive. When executing tasks, provide clear updates
  on what you're doing. If you need more information to complete a task, ask for it.
  """

  @doc """
  Creates a new ChatOpenAI model instance
  """
  def create_chat_model(opts \\ []) do
    api_key = Application.get_env(:openai_ex, :api_key) ||
      Application.get_env(:langchain, :openai_api_key)

    if is_nil(api_key) || api_key == "" do
      {:error, :no_api_key}
    else
      # Get model from opts, env, or use default
      model = Keyword.get(opts, :model) ||
        System.get_env("OPENAI_MODEL") ||
        @default_model

      temperature = Keyword.get(opts, :temperature, @temperature)

      ChatOpenAI.new!(%{
        api_key: api_key,
        model: model,
        temperature: temperature,
        stream: Keyword.get(opts, :stream, false),
        max_tokens: Keyword.get(opts, :max_tokens, @max_tokens)
      })
    end
  end

  @doc """
  Creates an LLM chain for conversation
  """
  def create_conversation_chain(opts \\ []) do
    case create_chat_model(opts) do
      {:error, reason} -> {:error, reason}
      chat_model ->
        {:ok, LLMChain.new!(%{
          llm: chat_model,
          verbose: false
        })}
    end
  end

  @doc """
  Processes a message with tools/functions available
  """
  def process_message_with_tools(messages, functions, opts \\ []) do
    case create_chat_model(opts) do
      {:error, reason} ->
        {:error, reason}

      chat_model ->
        # Add system message if not present
        messages = ensure_system_message(messages)

        # Create a chain instance with the chat model
        try do
          # Create the chain with the llm and tools
          chain_opts = %{
            llm: chat_model,
            verbose: false
          }

          # Add tools if provided
          chain_opts = if functions && length(functions) > 0 do
            Map.put(chain_opts, :tools, functions)
          else
            chain_opts
          end

          chain = LLMChain.new!(chain_opts)

          # Add all messages to the chain
          chain_with_messages =
            Enum.reduce(messages, chain, fn message, acc ->
              LangChain.Chains.LLMChain.add_message(acc, message)
            end)

          # Run the chain
          case LangChain.Chains.LLMChain.run(chain_with_messages) do
            {:ok, updated_chain} ->
              # Get the last message from the chain
              last_message = List.last(updated_chain.messages)
              {:ok, last_message}

            {:error, reason} ->
              Logger.error("LangChain run error: #{inspect(reason)}")
              {:error, :langchain_error}

            # Sometimes errors come as a different pattern
            error ->
              Logger.error("Unexpected LangChain response: #{inspect(error)}")
              {:error, :langchain_error}
          end
        rescue
          e ->
            Logger.error("Langchain error: #{inspect(e)}")
            Logger.error(Exception.format(:error, e, __STACKTRACE__))
            {:error, :langchain_error}
        end
    end
  end

  @doc """
  Generates embeddings for text
  """
  def generate_embedding(text) when is_binary(text) do
    api_key = Application.get_env(:openai_ex, :api_key) ||
      Application.get_env(:langchain, :openai_api_key)

    if is_nil(api_key) || api_key == "" do
      {:error, :no_api_key}
    else
      # Make direct API request to OpenAI using Finch
      try do
        headers = [
          {"Authorization", "Bearer #{api_key}"},
          {"Content-Type", "application/json"}
        ]
        
        body = Jason.encode!(%{
          model: "text-embedding-3-small",
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
  Retreives Langchain Function definitions from available tools.
  """
  def get_tool_functions do
    Tools.available_tools()
  end

  defp ensure_system_message(messages) do
    # Convert all messages to LangChain Message structs first
    langchain_messages = to_langchain_messages(messages)

    # Check if we already have a system message
    has_system = Enum.any?(langchain_messages, fn msg ->
      msg.role == :system
    end)

    if has_system do
      langchain_messages
    else
      # Create system message using bang version
      system_msg = Message.new_system!(@system_prompt)
      [system_msg | langchain_messages]
    end
  end

  @doc """
  Converts messages to Langchain Message format
  """
  def to_langchain_messages(messages) when is_list(messages) do
    Enum.map(messages, &to_langchain_message/1)
  end

  defp to_langchain_message(%LangChain.Message{} = msg), do: msg

  defp to_langchain_message(%{role: "system", content: content}) when is_binary(content) do
    Message.new_system!(content)
  end

  defp to_langchain_message(%{role: "user", content: content}) when is_binary(content) do
    Message.new_user!(content)
  end

  defp to_langchain_message(%{role: "assistant", content: content}) when is_binary(content) do
    Message.new_assistant!(content)
  end

  defp to_langchain_message(%{"role" => role, "content" => content}) do
    to_langchain_message(%{role: role, content: content})
  end

  defp to_langchain_message(%JumpAgent.AI.Message{role: role, content: content}) do
    to_langchain_message(%{role: role, content: content})
  end

  defp to_langchain_message(msg) do
    Logger.warning("Unknown message format: #{inspect(msg)}")
    Message.new_user!(inspect(msg))
  end
end
