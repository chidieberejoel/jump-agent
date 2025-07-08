defmodule JumpAgent.AI.Agent do
  @moduledoc """
  The core AI agent that processes messages and executes tasks.
  """

  alias JumpAgent.AI
  alias JumpAgent.AI.{Tools, EmbeddingService, VectorSearch}
  alias JumpAgent.Accounts
  require Logger

  @openai_model "gpt-4-turbo-preview"
  @system_prompt """
  You are an intelligent assistant for managing professional relationships and communications.
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

      # Search for relevant documents
      relevant_docs = AI.search_similar_documents(user, message_content, limit: 5)

      # Build messages for OpenAI
      messages = build_messages(context, message_content, relevant_docs)

      # Get available tools
      tools = Tools.available_tools()

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
          {:error, "I'm having trouble processing your request. Please try again."}
      end
    rescue
      error ->
        AI.Metrics.track_error(user.id, "chat_completion", error)
        Logger.error("Error processing message: #{inspect(error)}")
        {:error, "An unexpected error occurred. Please try again."}
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

  defp build_messages(context, new_message, relevant_docs) do
    # Start with system message
    messages = [%{role: "system", content: @system_prompt}]

    # Add context from relevant documents
    if relevant_docs != [] do
      doc_context = build_document_context(relevant_docs)
      messages = messages ++ [%{role: "system", content: "Relevant context from your data:\n#{doc_context}"}]
    end

    # Add conversation history
    history_messages = Enum.map(context.messages, fn msg ->
      %{role: msg.role, content: msg.content}
    end)

    messages = messages ++ history_messages

    # Add the new user message
    messages ++ [%{role: "user", content: new_message}]
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
    JumpAgent.AI.OpenAIClient.chat_completion(messages, tools,
      model: @openai_model,
      temperature: 0.7,
      max_tokens: 1000
    )
    |> case do
         {:ok, %{choices: [choice | _]}} ->
           {:ok, choice.message}
         error ->
           error
       end
  end

  defp process_openai_response(conversation, message) do
    # Save the assistant message
    {:ok, ai_message} = AI.create_message(conversation, %{
      role: "assistant",
      content: message.content || "",
      tool_calls: message.tool_calls || []
    })

    # Process any tool calls
    if message.tool_calls && message.tool_calls != [] do
      process_tool_calls(conversation, ai_message, message.tool_calls)
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
        type: tool_call.function.name,
        parameters: Jason.decode!(tool_call.function.arguments),
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
