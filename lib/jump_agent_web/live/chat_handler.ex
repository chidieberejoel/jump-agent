defmodule JumpAgentWeb.ChatHandler do
  @moduledoc """
  Handles chat interactions with Langchain, including streaming support.
  """

  alias JumpAgent.AI
  alias JumpAgent.AI.{LangchainService, LangchainFunctionExecutor}
  alias LangChain.Message
  alias Phoenix.LiveView
  require Logger

  @doc """
  Processes a chat message with optional streaming to LiveView
  """
  def process_chat_message(conversation, message_content, opts \\ []) do
    live_view_pid = Keyword.get(opts, :live_view_pid)
    stream = Keyword.get(opts, :stream, false)

    user = JumpAgent.Accounts.get_user!(conversation.user_id)

    # Get conversation context
    context = AI.get_conversation_context(conversation)

    # Search for relevant documents
    relevant_docs = search_relevant_documents(user, message_content)

    # Build messages
    messages = build_messages(context, message_content, relevant_docs)

    # Get functions
    functions = LangchainService.get_tool_functions()

    if stream && live_view_pid do
      process_with_streaming(messages, functions, user, conversation, live_view_pid)
    else
      process_without_streaming(messages, functions, user, conversation)
    end
  end

  defp process_with_streaming(messages, functions, user, conversation, live_view_pid) do
    # Create streaming chat model
    case LangchainService.create_chat_model(stream: true) do
      {:error, reason} ->
        {:error, reason}

      chat_model ->
        # Create a chain
        chain = LangChain.Chains.LLMChain.new!(%{
          llm: chat_model,
          verbose: false
        })

        # Start streaming
        Task.start(fn ->
          accumulated_content = ""

          # Stream handler
          stream_handler = fn
            {:data, delta} ->
              accumulated_content = accumulated_content <> (delta.content || "")
              # Send delta to LiveView
              send(live_view_pid, {:chat_delta, delta.content})

            {:done, _} ->
              # Save complete message
              {:ok, ai_message} = AI.create_message(conversation, %{
                role: "assistant",
                content: accumulated_content,
                tool_calls: []
              })

              send(live_view_pid, {:chat_complete, ai_message})

            {:error, reason} ->
              send(live_view_pid, {:chat_error, reason})
          end

          # Run chain with streaming
          LangChain.Chains.LLMChain.stream(
            chain,
            messages: messages,
            functions: functions,
            callback: stream_handler
          )
        end)

        {:ok, :streaming}
    end
  end

  defp process_without_streaming(messages, functions, user, conversation) do
    case LangchainService.create_chat_model() do
      {:error, reason} ->
        {:error, reason}

      chat_model ->
        chain = LangChain.Chains.LLMChain.new!(%{
          llm: chat_model,
          verbose: false
        })

        case LangChain.Chains.LLMChain.run(chain, messages: messages, functions: functions) do
          {:ok, response} ->
            # Handle function calls if any
            content = if response.function_calls && length(response.function_calls) > 0 do
              execute_functions_and_format(response, user)
            else
              response.content
            end

            # Save message
            {:ok, ai_message} = AI.create_message(conversation, %{
              role: "assistant",
              content: content,
              tool_calls: []
            })

            {:ok, ai_message}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp execute_functions_and_format(response, user) do
    function_results = Enum.map(response.function_calls, fn call ->
      args = parse_function_args(call.arguments)
      LangchainFunctionExecutor.execute_function(call.name, args, user)
    end)

    format_response_with_results(response.content, function_results)
  end

  defp parse_function_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, parsed} -> parsed
      _ -> %{}
    end
  end
  defp parse_function_args(args) when is_map(args), do: args
  defp parse_function_args(_), do: %{}

  defp format_response_with_results(content, results) do
    results_text = Enum.map(results, fn
      {:ok, result} -> "\n✓ #{format_result(result)}"
      {:error, error} -> "\n✗ Error: #{error}"
    end) |> Enum.join("")

    (content || "") <> results_text
  end

  defp format_result(%{"status" => status} = result) do
    Map.get(result, "message", status)
  end
  defp format_result(result) when is_map(result) do
    inspect(result)
  end

  defp search_relevant_documents(user, query) do
    case AI.search_similar_documents(user, query, limit: 5) do
      docs when is_list(docs) -> docs
      _ -> []
    end
  rescue
    _ -> []
  end

  defp build_messages(context, new_message, relevant_docs) do
    messages = []

    # Add document context if available
    messages = if relevant_docs != [] do
      doc_context = format_document_context(relevant_docs)
      messages ++ [Message.new_system("Relevant context:\n#{doc_context}")]
    else
      messages
    end

    # Add conversation history
    history = context.messages
              |> Enum.take(-10)
              |> Enum.map(&to_langchain_message/1)

    messages ++ history ++ [Message.new_user(new_message)]
  end

  defp to_langchain_message(%{role: "system", content: content}), do: Message.new_system(content)
  defp to_langchain_message(%{role: "user", content: content}), do: Message.new_user(content)
  defp to_langchain_message(%{role: "assistant", content: content}), do: Message.new_assistant(content)

  defp format_document_context(docs) do
    Enum.map(docs, fn doc ->
      "#{doc.source_type}: #{doc.content}"
    end) |> Enum.join("\n\n")
  end
end
