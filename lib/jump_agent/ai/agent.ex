defmodule JumpAgent.AI.Agent do
  @moduledoc """
  The core AI agent that processes messages and executes tasks.
  """

  alias JumpAgent.AI
  alias JumpAgent.AI.{Tools, EmbeddingService, VectorSearch}
  alias JumpAgent.Accounts
  require Logger

  # Use a valid OpenAI model
  @openai_model "gpt-4-turbo"
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
  Processes a user message and generates a response.
  """
  def process_message(conversation, message_content) do
    start_time = System.monotonic_time(:millisecond)
    user = Accounts.get_user!(conversation.user_id)

    try do
      # Get conversation context
      context = AI.get_conversation_context(conversation)

      # Try to search for relevant documents, but don't fail if embeddings are unavailable
      relevant_docs = try_search_documents(user, message_content)

      # Build messages for OpenAI
      messages = build_messages(context, message_content, relevant_docs)

      # Get available tools - for now, let's disable tools to test basic chat
      # tools = Tools.available_tools()
      tools = nil

      # Call OpenAI
      case call_openai(messages, tools) do
        {:ok, response} ->
          duration = System.monotonic_time(:millisecond) - start_time
          AI.Metrics.track_request(user.id, "chat_completion", duration)
          process_openai_response(conversation, response)

        {:error, reason} ->
          duration = System.monotonic_time(:millisecond) - start_time
          AI.Metrics.track_error(user.id, "chat_completion", reason)
          Logger.error("OpenAI call failed: #{inspect(reason)}")

          # Create a more informative error message
          error_msg = case reason do
            {:api_error, msg} -> "API Error: #{msg}"
            :no_api_key -> "OpenAI API key is not configured. Please set the OPENAI_API_KEY environment variable."
            :timeout -> "The request timed out. Please try again."
            _ -> "I'm having trouble processing your request. Please check the logs for more details."
          end

          {:error, error_msg}
      end
    rescue
      error ->
        AI.Metrics.track_error(user.id, "chat_completion", error)
        Logger.error("Error processing message: #{inspect(error)}")
        Logger.error(Exception.format(:error, error, __STACKTRACE__))
        {:error, "An unexpected error occurred: #{inspect(error)}. Please check the server logs."}
    end
  end

  @doc """
  Processes a triggered instruction based on an external event.
  """
  def process_instruction_trigger(user, instruction, event_data) do
    # Check if conditions match
    if check_conditions(instruction.conditions, event_data) do
      # Create a system conversation for this trigger
      {:ok, conversation} = AI.create_conversation(user, %{
        title: "Automated: #{instruction.trigger_type}",
        context: %{
          "instruction_id" => instruction.id,
          "trigger_type" => instruction.trigger_type,
          "event_data" => event_data
        }
      })

      # Process the instruction
      system_message = build_instruction_prompt(instruction, event_data)
      process_message(conversation, system_message)
    end
  end

  defp try_search_documents(user, message_content) do
    try do
      case AI.search_similar_documents(user, message_content, limit: 5) do
        docs when is_list(docs) -> docs
        _ -> []
      end
    rescue
      error ->
        Logger.warning("Failed to search documents: #{inspect(error)}. Continuing without document context.")
        []
    catch
      :exit, reason ->
        Logger.warning("Document search process exited: #{inspect(reason)}. Continuing without document context.")
        []
    end
  end

  defp build_messages(context, new_message, relevant_docs) do
    # Start with system message
    messages = [%{"role" => "system", "content" => @system_prompt}]

    # Add context from relevant documents if available
    if relevant_docs != [] do
      doc_context = build_document_context(relevant_docs)
      messages = messages ++ [%{"role" => "system", "content" => "Relevant context from your data:\n#{doc_context}"}]
    end

    # Add conversation history (limit to prevent token overflow)
    history_messages =
      context.messages
      |> Enum.take(-10) # Only last 10 messages to prevent token limit issues
      |> Enum.map(fn msg ->
        %{"role" => msg.role, "content" => msg.content}
      end)

    messages = messages ++ history_messages

    # Add the new user message
    messages ++ [%{"role" => "user", "content" => new_message}]
  end

  defp build_document_context(docs) do
    docs
    |> Enum.map(fn doc ->
      source = format_source(doc.source_type, doc.metadata)
      "#{source}: #{doc.content}"
    end)
    |> Enum.join("\n\n")
  end

  defp format_source("gmail", metadata) do
    "Email from #{metadata["from"]} (#{metadata["date"]})"
  end
  defp format_source("hubspot_contact", metadata) do
    "HubSpot Contact: #{metadata["name"] || metadata["email"]}"
  end
  defp format_source("hubspot_note", metadata) do
    "HubSpot Note for #{metadata["contact_name"]}"
  end
  defp format_source("calendar", metadata) do
    "Calendar Event: #{metadata["title"]} (#{metadata["date"]})"
  end
  defp format_source(type, _), do: String.capitalize(type)

  defp call_openai(messages, tools) do
    # Check if API key is configured
    api_key = Application.get_env(:openai_ex, :api_key)

    if is_nil(api_key) || api_key == "" do
      {:error, :no_api_key}
    else
      JumpAgent.AI.OpenAIClient.chat_completion(messages, tools,
        model: @openai_model,
        temperature: 0.7,
        max_tokens: 1000
      )
      |> case do
           {:ok, %{"choices" => [%{"message" => message} | _]}} ->
             {:ok, message}
           {:ok, response} ->
             Logger.error("Unexpected OpenAI response format: #{inspect(response)}")
             {:error, {:api_error, "Unexpected response format"}}
           {:error, reason} = error ->
             Logger.error("OpenAI API error: #{inspect(reason)}")
             error
         end
    end
  end

  defp process_openai_response(conversation, message) do
    content = message["content"] || ""

    # Save the assistant message
    {:ok, ai_message} = AI.create_message(conversation, %{
      role: "assistant",
      content: content,
      tool_calls: message["tool_calls"] || []
    })

    # Process any tool calls if they exist
    if message["tool_calls"] && message["tool_calls"] != [] do
      process_tool_calls(conversation, ai_message, message["tool_calls"])
    end

    {:ok, ai_message}
  end

  defp process_tool_calls(conversation, ai_message, tool_calls) do
    user = Accounts.get_user!(conversation.user_id)

    Enum.each(tool_calls, fn tool_call ->
      # Create a task for this tool call
      {:ok, task} = AI.create_task(user, %{
        conversation_id: conversation.id,
        message_id: ai_message.id,
        type: tool_call["function"]["name"],
        parameters: Jason.decode!(tool_call["function"]["arguments"]),
        status: "pending"
      })

      # Queue the task for execution
      %{task_id: task.id}
      |> JumpAgent.Workers.TaskExecutorWorker.new()
      |> Oban.insert()
    end)
  end

  defp check_conditions(conditions, event_data) when conditions == %{}, do: true
  defp check_conditions(conditions, event_data) do
    Enum.all?(conditions, fn {key, expected_value} ->
      actual_value = get_in(event_data, String.split(key, "."))
      matches_condition?(actual_value, expected_value)
    end)
  end

  defp matches_condition?(actual, expected) when is_map(expected) do
    case Map.get(expected, "operator") do
      "equals" -> actual == expected["value"]
      "contains" -> String.contains?(to_string(actual), expected["value"])
      "starts_with" -> String.starts_with?(to_string(actual), expected["value"])
      _ -> false
    end
  end
  defp matches_condition?(actual, expected), do: actual == expected

  defp build_instruction_prompt(instruction, event_data) do
    """
    Execute the following instruction based on the triggered event:

    Instruction: #{instruction.instruction}

    Event Type: #{instruction.trigger_type}
    Event Data: #{Jason.encode!(event_data, pretty: true)}

    Please take the appropriate action based on this instruction and event.
    """
  end
end
