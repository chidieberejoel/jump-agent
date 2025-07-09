defmodule JumpAgent.AI.Agent do
  @moduledoc """
  The core AI agent that processes messages using Langchain.
  """

  alias JumpAgent.AI
  alias JumpAgent.AI.{LangchainService, LangchainFunctionExecutor}
  alias JumpAgent.Accounts
  alias LangChain.Message
  alias LangChain.Message.ToolCall
  require Logger

  @doc """
  Processes a user message and generates a response using Langchain.
  """
  def process_message(conversation, message_content) do
    start_time = System.monotonic_time(:millisecond)
    user = Accounts.get_user!(conversation.user_id)

    try do
      # Get conversation context
      context = AI.get_conversation_context(conversation)

      # Try to search for relevant documents
      relevant_docs = try_search_documents(user, message_content)

      # Build messages for Langchain
      messages = build_langchain_messages(context, message_content, relevant_docs)

      # Get available tool functions
      functions = LangchainService.get_tool_functions()

      # Process message with Langchain
      case process_with_langchain(messages, functions, user) do
        {:ok, response} ->
          duration = System.monotonic_time(:millisecond) - start_time
          AI.Metrics.track_request(user.id, "chat_completion", duration)

          # Save the assistant message
          {:ok, ai_message} = AI.create_message(conversation, %{
            role: "assistant",
            content: response.content,
            tool_calls: []  # Will be updated when we handle function calls
          })

          {:ok, ai_message}

        {:error, reason} ->
          duration = System.monotonic_time(:millisecond) - start_time
          AI.Metrics.track_error(user.id, "chat_completion", reason)
          Logger.error("Langchain processing failed: #{inspect(reason)}")

          error_msg = format_error_message(reason)
          {:error, error_msg}
      end
    rescue
      error ->
        AI.Metrics.track_error(user.id, "chat_completion", error)
        Logger.error("Error processing message: #{inspect(error)}")
        Logger.error(Exception.format(:error, error, __STACKTRACE__))
        {:error, "An unexpected error occurred: #{Exception.message(error)}"}
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

  # Private functions

  defp process_with_langchain(messages, functions, user) do
    # Use the existing LangchainService function that properly handles messages
    case LangchainService.process_message_with_tools(messages, functions) do
      {:ok, %LangChain.Message{} = message} ->
        # Direct message response
        handle_langchain_response(message, user)

      {:ok, %LangChain.Chains.LLMChain{} = chain} ->
        # Chain response - get the last message
        last_message = List.last(chain.messages)
        handle_langchain_response(last_message, user)

      {:ok, response} when is_binary(response) ->
        # String response - convert to message
        {:ok, Message.new_assistant(response)}

      {:error, :no_api_key} ->
        {:error, :no_api_key}

      {:error, :langchain_error} ->
        {:error, "Failed to process message with AI. Please try again."}

      {:error, reason} ->
        Logger.error("Langchain processing failed: #{inspect(reason)}")
        {:error, format_error_message(reason)}
    end
  end

  defp handle_langchain_response(response, user) when is_struct(response, LangChain.Message) do
    # Check if there are tool calls (not function_calls)
    if response.tool_calls && length(response.tool_calls) > 0 do
      # Execute tool calls
      function_results = Enum.map(response.tool_calls, fn tool_call ->
        execute_function_call(tool_call, user)
      end)

      # For now, return the response with function results appended
      # In a real implementation, you might want to send these back to the LLM
      content = build_response_with_results(response.content, function_results)

      # Create a new assistant message with the content
      assistant_msg = case Message.new_assistant(content) do
        {:ok, msg} -> msg
        msg -> msg
      end

      {:ok, assistant_msg}
    else
      # No tool calls, return the response as is
      {:ok, response}
    end
  end

  defp handle_langchain_response(response, _user) do
    # Handle other response types
    content = to_string(response)
    assistant_msg = case Message.new_assistant(content) do
      {:ok, msg} -> msg
      msg -> msg
    end
    {:ok, assistant_msg}
  end

  defp execute_function_call(%ToolCall{name: name, arguments: args}, user) do
    # Parse arguments if they're a JSON string
    arguments = case args do
      args when is_binary(args) ->
        case Jason.decode(args) do
          {:ok, parsed} -> parsed
          _ -> %{}
        end
      args when is_map(args) -> args
      _ -> %{}
    end

    case LangchainFunctionExecutor.execute_function(name, arguments, user) do
      {:ok, result} ->
        %{function: name, status: "success", result: result}

      {:error, error} ->
        %{function: name, status: "error", error: error}
    end
  end

  defp build_response_with_results(nil, function_results), do: build_response_with_results("", function_results)
  defp build_response_with_results(content, []), do: content
  defp build_response_with_results(content, function_results) do
    results_text = Enum.map(function_results, fn result ->
      case result do
        %{status: "success", function: func, result: data} ->
          "\n✓ #{humanize_function_name(func)}: #{format_function_result(func, data)}"

        %{status: "error", function: func, error: error} ->
          "\n✗ #{humanize_function_name(func)} failed: #{error}"
      end
    end) |> Enum.join("")

    if content && content != "" do
      content <> "\n" <> results_text
    else
      results_text
    end
  end

  defp humanize_function_name("search_information"), do: "Search"
  defp humanize_function_name("send_email"), do: "Email sent"
  defp humanize_function_name("create_calendar_event"), do: "Calendar event created"
  defp humanize_function_name("create_contact"), do: "Contact created"
  defp humanize_function_name("update_contact"), do: "Contact updated"
  defp humanize_function_name("add_hubspot_note"), do: "Note added"
  defp humanize_function_name("schedule_meeting"), do: "Meeting request sent"
  defp humanize_function_name(name), do: name

  defp format_function_result("search_information", %{"total" => total, "query" => query}) do
    "Found #{total} results for '#{query}'"
  end
  defp format_function_result("send_email", %{"to" => to, "subject" => subject}) do
    "Email '#{subject}' sent to #{to}"
  end
  defp format_function_result("create_calendar_event", %{"title" => title}) do
    "'#{title}'"
  end
  defp format_function_result("create_contact", %{"email" => email}) do
    "#{email}"
  end
  defp format_function_result("schedule_meeting", %{"contact_email" => email, "meeting_title" => title}) do
    "Meeting '#{title}' request sent to #{email}"
  end
  defp format_function_result(_, %{"status" => status}), do: status
  defp format_function_result(_, _), do: "Completed"

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

  defp build_langchain_messages(context, new_message, relevant_docs) do
    messages = []

    # Add context from relevant documents if available
    messages = if relevant_docs != [] do
      doc_context = build_document_context(relevant_docs)
      # Handle the tuple return from Message.new_system
      system_msg = case Message.new_system("Relevant context from your data:\n#{doc_context}") do
        {:ok, msg} -> msg
        msg -> msg
      end
      messages ++ [system_msg]
    else
      messages
    end

    # Add conversation history
    history_messages = context.messages
                       |> Enum.take(-10)  # Only last 10 messages
                       |> Enum.map(&convert_to_langchain_message/1)

    messages = messages ++ history_messages

    # Add the new user message
    # Handle the tuple return from Message.new_user
    user_msg = case Message.new_user(new_message) do
      {:ok, msg} -> msg
      msg -> msg
    end

    messages ++ [user_msg]
  end

  defp convert_to_langchain_message(%{role: "system", content: content}) do
    case Message.new_system(content) do
      {:ok, message} -> message
      message -> message  # In case it returns the message directly
    end
  end

  defp convert_to_langchain_message(%{role: "user", content: content}) do
    case Message.new_user(content) do
      {:ok, message} -> message
      message -> message
    end
  end

  defp convert_to_langchain_message(%{role: "assistant", content: content}) do
    case Message.new_assistant(content) do
      {:ok, message} -> message
      message -> message
    end
  end

  # Also add this catch-all for other message types
  defp convert_to_langchain_message(%{"role" => role, "content" => content}) do
    convert_to_langchain_message(%{role: role, content: content})
  end

  defp convert_to_langchain_message(msg) do
    Logger.warning("Unknown message format: #{inspect(msg)}")
    # Default to user message
    case Message.new_user(inspect(msg)) do
      {:ok, message} -> message
      message -> message
    end
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

  defp format_error_message(:no_api_key) do
    "OpenAI API key is not configured. Please set the OPENAI_API_KEY environment variable."
  end
  defp format_error_message({:api_error, msg}) do
    "API Error: #{msg}"
  end
  defp format_error_message(:timeout) do
    "The request timed out. Please try again."
  end
  defp format_error_message(error) do
    "I'm having trouble processing your request. Error: #{inspect(error)}"
  end
end
