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
    case LangchainService.process_message_with_tools(messages, functions) do
      {:ok, %LangChain.Message{} = message} ->
        handle_langchain_response(message, user)

      {:ok, %LangChain.Chains.LLMChain{} = chain} ->
        # Chain response - get the last message
        last_message = List.last(chain.messages)
        handle_langchain_response(last_message, user)

      {:ok, response} when is_binary(response) ->
        # String response - convert to message
        msg = case Message.new_assistant(response) do
          {:ok, m} -> m
          m -> m
        end
        {:ok, msg}

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
    if response.tool_calls && length(response.tool_calls) > 0 do
      function_results = Enum.map(response.tool_calls, fn tool_call ->
        execute_function_call(tool_call, user)
      end)

      # For now, return the response with function results appended
      content = build_response_with_results(response.content, function_results)

      # Create a new assistant message
      assistant_msg = Message.new_assistant!(content)
      {:ok, assistant_msg}
    else
      {:ok, response}
    end
  end

  defp handle_langchain_response(response, _user) do
    Logger.info("Handling non-message response: #{inspect(response)}")

    # Handle other response types
    content = to_string(response)
    assistant_msg = Message.new_assistant!(content)
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

  defp format_function_result("search_information", %{"results" => results, "count" => count}) when count > 0 do
    # Format the search results nicely
    results_text = results
                   |> Enum.take(5)  # Show top 5 results
                   |> Enum.map_join("\n\n", fn result ->
      # Handle both "source" and "source_type" keys
      source = String.capitalize(
        result["source"] || result["source_type"] ||
          result[:source] || result[:source_type] || "Unknown"
      )
      content = String.slice(result["content"] || result[:content] || "", 0, 200)
      similarity = Float.round((result["similarity"] || result[:similarity] || 0) * 100, 1)

      "• [#{source}] (#{similarity}% match)\n  #{content}..."
    end)

    "Found #{count} results:\n\n#{results_text}"
  end

  defp format_function_result("search_information", %{"results" => _, "count" => 0}) do
    "No results found"
  end

  defp format_function_result("search_information", %{"total" => total, "query" => query}) do
    # Fallback format
    "Found #{total} results for '#{query}'"
  end

  defp format_function_result("search_information", %{"error" => error}) do
    "Search unavailable: #{error}"
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
  defp format_function_result(_, result) when is_map(result) do
    # Generic formatting for any other result
    if Map.has_key?(result, "count") || Map.has_key?(result, "results") do
      count = result["count"] || length(result["results"] || [])
      "Found #{count} items"
    else
      "Completed"
    end
  end
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
      # Use bang version
      system_msg = Message.new_system!("Relevant context from your data:\n#{doc_context}")
      messages ++ [system_msg]
    else
      messages
    end

    # Add conversation history
    history_messages = context.messages
                       |> Enum.take(-10)  # Only last 10 messages
                       |> Enum.map(&convert_to_langchain_message/1)

    messages = messages ++ history_messages

    user_msg = Message.new_user!(new_message)
    messages ++ [user_msg]
  end

    defp convert_to_langchain_message(%{role: "system", content: content}) when is_binary(content) do
      Message.new_system!(content)
    end

    defp convert_to_langchain_message(%{role: "user", content: content}) when is_binary(content) do
      Message.new_user!(content)
    end

    defp convert_to_langchain_message(%{role: "assistant", content: content}) when is_binary(content) do
      Message.new_assistant!(content)
    end

    defp convert_to_langchain_message(%JumpAgent.AI.Message{role: role, content: content}) do
      convert_to_langchain_message(%{role: role, content: content})
    end

    defp convert_to_langchain_message(%{"role" => role, "content" => content}) do
      convert_to_langchain_message(%{role: role, content: content})
    end

    defp convert_to_langchain_message(other) do
      Logger.error("Cannot convert to langchain message: #{inspect(other)}")
      Message.new_user!("Error: Invalid message format")
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
    # Build more specific prompts based on trigger type
    base_prompt = """
    You are processing an automated instruction triggered by an event.

    INSTRUCTION: #{instruction.instruction}

    EVENT TYPE: #{instruction.trigger_type}
    """

    case instruction.trigger_type do
      "email_received" ->
        base_prompt <> """

        EMAIL DATA:
        - From: #{event_data["from"]}
        - Subject: #{event_data["subject"]}
        - Content Preview: #{String.slice(event_data["content"] || "", 0, 200)}...
        - Date: #{event_data["date"]}

        You have access to these tools:
        - search_information: Search your knowledge base
        - send_email: Send emails
        - create_contact: Create a HubSpot contact
        - add_hubspot_note: Add notes to HubSpot contacts

        Execute the instruction using the appropriate tools based on the email data above.
        """

      "calendar_event_created" ->
        base_prompt <> """

        CALENDAR EVENT DATA:
        - Title: #{event_data["summary"]}
        - Start: #{event_data["start"]}
        - End: #{event_data["end"]}
        - Location: #{event_data["location"] || "Not specified"}
        - Attendees: #{format_attendees(event_data["attendees"])}

        Note: When sending emails to attendees, exclude any attendee marked as "self": true

        You have access to these tools:
        - send_email: Send emails to attendees
        - create_calendar_event: Create calendar events

        Execute the instruction using the appropriate tools based on the event data above.
        """

      "hubspot_contact_created" ->
        base_prompt <> """

        NEW CONTACT DATA:
        - Name: #{event_data["full_name"]}
        - Email: #{event_data["email"]}
        - Company: #{event_data["company"] || "Not specified"}
        - Phone: #{event_data["phone"] || "Not specified"}

        You have access to these tools:
        - send_email: Send emails
        - add_hubspot_note: Add notes to contacts
        - create_calendar_event: Schedule meetings

        Execute the instruction using the appropriate tools based on the contact data above.
        """

      "hubspot_contact_updated" ->
        base_prompt <> """

        UPDATED CONTACT DATA:
        - Name: #{event_data["full_name"]}
        - Email: #{event_data["email"]}
        - Company: #{event_data["company"] || "Not specified"}
        - Changed Fields: Check the properties in the data

        Full contact properties: #{Jason.encode!(event_data["properties"], pretty: true)}

        You have access to these tools:
        - send_email: Send emails
        - add_hubspot_note: Add notes to contacts

        Execute the instruction using the appropriate tools based on the contact update above.
        """

      _ ->
        base_prompt <> """

        EVENT DATA:
        #{Jason.encode!(event_data, pretty: true)}

        Please take the appropriate action based on this instruction and event.
        Use any available tools as needed to complete the instruction.
        """
    end
  end

  defp format_attendees(nil), do: "None"
  defp format_attendees([]), do: "None"
  defp format_attendees(attendees) do
    attendees
    |> Enum.map(fn a ->
      self_indicator = if a["self"], do: " (you)", else: ""
      "#{a["email"]} - #{a["display_name"] || "No name"}#{self_indicator}"
    end)
    |> Enum.join("\n  ")
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
