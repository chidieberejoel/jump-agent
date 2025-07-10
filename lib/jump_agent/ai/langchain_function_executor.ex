defmodule JumpAgent.AI.LangchainFunctionExecutor do
  @moduledoc """
  Executes functions/tools called by the Langchain AI agent.
  """

  alias JumpAgent.{GoogleAPI, HubSpotAPI, HubSpot, AI}
  alias JumpAgent.AI.{VectorSearch, EmbeddingService}
  require Logger

  @doc """
  Executes a function call from Langchain
  """
  def execute_function(function_name, arguments, user) do
    Logger.info("Executing function: #{function_name} with args: #{inspect(arguments)}")

    try do
      case function_name do
        "search_information" -> search_information(arguments, user)
        "send_email" -> send_email(arguments, user)
        "schedule_meeting" -> schedule_meeting(arguments, user)
        "create_calendar_event" -> create_calendar_event(arguments, user)
        "create_contact" -> create_contact(arguments, user)
        "update_contact" -> update_contact(arguments, user)
        "add_hubspot_note" -> add_hubspot_note(arguments, user)
        _ -> {:error, "Unknown function: #{function_name}"}
      end
    rescue
      error ->
        Logger.error("Function execution error: #{inspect(error)}")
        {:error, "Function execution failed: #{Exception.message(error)}"}
    end
  end

  # Function implementations

  defp search_information(%{"query" => query} = args, user) do
    source_types = Map.get(args, "source_types", nil)

    # Use EmbeddingService to generate embedding
    case EmbeddingService.generate_embedding(query) do
      {:ok, embedding} ->
        results = VectorSearch.search_documents(
          user.id,
          embedding,
          20,  # limit
          0.7, # threshold
          source_types
        )

        formatted_results = Enum.map(results, fn result ->
          %{
            source: result.source_type,
            content: result.content,
            metadata: result.metadata,
            similarity: result.similarity
          }
        end)

        {:ok, %{"results" => formatted_results, "count" => length(formatted_results)}}

      {:error, reason} ->
        Logger.error("Failed to generate embedding: #{inspect(reason)}")
        {:error, "Search failed: Unable to process query"}
    end
  end

  defp send_email(params, user) do
    message = %{
                to: params["to"],
                subject: params["subject"],
                body: params["body"],
                cc: params["cc"],
                bcc: params["bcc"]
              }
              |> Enum.reject(fn {_, v} -> is_nil(v) end)
              |> Map.new()

    case GoogleAPI.send_email(user, message) do
      {:ok, %{"id" => message_id}} ->
        {:ok, %{
          "message_id" => message_id,
          "status" => "sent",
          "to" => params["to"],
          "subject" => params["subject"]
        }}

      {:error, reason} ->
        {:error, format_api_error("Google", reason)}
    end
  end

  defp create_calendar_event(params, user) do
    event = %{
              summary: params["title"],
              start: %{dateTime: params["start_time"], timeZone: "UTC"},
              end: %{dateTime: params["end_time"], timeZone: "UTC"},
              description: params["description"],
              location: params["location"],
              attendees: build_attendees(params["attendees"])
            }
            |> Enum.reject(fn {_, v} -> is_nil(v) end)
            |> Map.new()

    case GoogleAPI.create_calendar_event(user, event) do
      {:ok, %{"id" => event_id} = response} ->
        {:ok, %{
          "event_id" => event_id,
          "html_link" => response["htmlLink"],
          "status" => "created",
          "title" => params["title"]
        }}

      {:error, reason} ->
        {:error, format_api_error("Google Calendar", reason)}
    end
  end

  defp create_contact(params, user) do
    connection = HubSpot.get_connection_by_user(user)

    if connection do
      properties = %{
                     "email" => params["email"],
                     "firstname" => params["first_name"],
                     "lastname" => params["last_name"],
                     "company" => params["company"],
                     "phone" => params["phone"]
                   }
                   |> Enum.reject(fn {_, v} -> is_nil(v) end)
                   |> Map.new()

      case HubSpotAPI.create_contact(connection, properties) do
        {:ok, %{"id" => contact_id} = response} ->
          # Create embedding for the new contact
          create_contact_embedding(user, response)

          {:ok, %{
            "contact_id" => contact_id,
            "status" => "created",
            "email" => params["email"]
          }}

        {:error, reason} ->
          {:error, format_api_error("HubSpot", reason)}
      end
    else
      {:error, "HubSpot not connected. Please connect your HubSpot account first."}
    end
  end

  defp update_contact(params, user) do
    connection = HubSpot.get_connection_by_user(user)

    if connection do
      email = params["email"]
      properties = params["properties"] || %{}

      # Find contact by email
      case find_contact_by_email(connection, email) do
        {:ok, contact_id} ->
          case HubSpotAPI.update_contact(connection, contact_id, properties) do
            {:ok, response} ->
              # Update embedding
              update_contact_embedding(user, contact_id, response)

              {:ok, %{
                "contact_id" => contact_id,
                "status" => "updated",
                "email" => email
              }}

            {:error, reason} ->
              {:error, format_api_error("HubSpot", reason)}
          end

        {:error, :not_found} ->
          {:error, "Contact not found with email: #{email}"}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "HubSpot not connected. Please connect your HubSpot account first."}
    end
  end

  defp add_hubspot_note(params, user) do
    connection = HubSpot.get_connection_by_user(user)

    if connection do
      email = params["contact_email"]
      note_content = params["note_content"]

      case find_contact_by_email(connection, email) do
        {:ok, contact_id} ->
          engagement = %{
            engagement: %{
              active: true,
              type: "NOTE",
              timestamp: DateTime.utc_now() |> DateTime.to_unix(:millisecond)
            },
            associations: %{
              contactIds: [contact_id]
            },
            metadata: %{
              body: note_content
            }
          }

          case HubSpotAPI.create_engagement(connection, engagement) do
            {:ok, %{"engagement" => %{"id" => note_id}}} ->
              # Create embedding for the note
              create_note_embedding(user, contact_id, email, note_content)

              {:ok, %{
                "note_id" => note_id,
                "contact_id" => contact_id,
                "status" => "created"
              }}

            {:error, reason} ->
              {:error, format_api_error("HubSpot", reason)}
          end

        {:error, :not_found} ->
          {:error, "Contact not found with email: #{email}"}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "HubSpot not connected. Please connect your HubSpot account first."}
    end
  end

  defp schedule_meeting(params, user) do
    contact_email = params["contact_email"]
    meeting_title = params["meeting_title"]
    duration = params["duration_minutes"] || 30

    # Find available slots if not provided
    available_times = if params["preferred_times"] do
      params["preferred_times"]
    else
      find_available_calendar_slots(user, duration)
    end

    # Build scheduling email
    email_body = build_scheduling_email(
      meeting_title,
      available_times,
      params["message"]
    )

    email_params = %{
      "to" => contact_email,
      "subject" => "Meeting Request: #{meeting_title}",
      "body" => email_body
    }

    case send_email(email_params, user) do
      {:ok, result} ->
        {:ok, %{
          "status" => "email_sent",
          "email_message_id" => result["message_id"],
          "contact_email" => contact_email,
          "meeting_title" => meeting_title,
          "available_times" => available_times,
          "note" => "Meeting request email sent. Awaiting response from #{contact_email}."
        }}

      error ->
        error
    end
  end

  # Helper functions

  defp format_search_result(doc) do
    %{
      "source_type" => doc.source_type,
      "content" => doc.content,
      "metadata" => doc.metadata,
      "similarity" => doc.similarity,
      "created_at" => doc.created_at_source
    }
  end

  defp build_attendees(nil), do: nil
  defp build_attendees(emails) when is_list(emails) do
    Enum.map(emails, &%{email: &1})
  end

  defp find_contact_by_email(connection, email) do
    filters = [
      %{
        propertyName: "email",
        operator: "EQ",
        value: email
      }
    ]

    case HubSpotAPI.search_contacts(connection, filters, ["email"], 1) do
      {:ok, %{"results" => [%{"id" => contact_id} | _]}} ->
        {:ok, contact_id}
      {:ok, %{"results" => []}} ->
        {:error, :not_found}
      error ->
        error
    end
  end

  defp find_available_calendar_slots(user, duration_minutes) do
    # Simplified slot generation
    today = Date.utc_today()

    Enum.flat_map(1..5, fn day_offset ->
      date = Date.add(today, day_offset)

      [
        %{"date" => Date.to_string(date), "time" => "09:00"},
        %{"date" => Date.to_string(date), "time" => "14:00"},
        %{"date" => Date.to_string(date), "time" => "16:00"}
      ]
    end)
    |> Enum.take(6)
  end

  defp build_scheduling_email(meeting_title, available_times, additional_message) do
    times_text = available_times
                 |> Enum.map(fn slot -> "- #{slot["date"]} at #{slot["time"]}" end)
                 |> Enum.join("\n")

    base_message = """
    I'd like to schedule a meeting with you regarding: #{meeting_title}

    Here are some times that work for me:

    #{times_text}

    Please let me know which time works best for you, or suggest alternative times if none of these work.
    """

    if additional_message do
      base_message <> "\n\n#{additional_message}"
    else
      base_message
    end
  end

  defp create_contact_embedding(user, contact) do
    props = contact["properties"] || %{}

    content = [
                props["firstname"],
                props["lastname"],
                props["email"],
                props["company"]
              ]
              |> Enum.reject(&is_nil/1)
              |> Enum.join(" ")

    metadata = %{
      "name" => "#{props["firstname"]} #{props["lastname"]}",
      "email" => props["email"],
      "company" => props["company"]
    }

    prepared_content = EmbeddingService.prepare_content(content, metadata)

    AI.upsert_document_embedding(user, %{
      source_type: "hubspot_contact",
      source_id: contact["id"],
      content: prepared_content,
      metadata: props,
      created_at_source: contact["createdAt"]
    })
  end

  defp update_contact_embedding(user, contact_id, _updated_contact) do
    connection = HubSpot.get_connection_by_user(user)

    case HubSpotAPI.get_contact(connection, contact_id) do
      {:ok, contact} ->
        create_contact_embedding(user, contact)
      _ ->
        :ok
    end
  end

  defp create_note_embedding(user, contact_id, contact_email, note_content) do
    content = EmbeddingService.prepare_content(
      note_content,
      %{
        "contact_email" => contact_email,
        "contact_id" => contact_id
      }
    )

    AI.upsert_document_embedding(user, %{
      source_type: "hubspot_note",
      source_id: "#{contact_id}_#{DateTime.utc_now() |> DateTime.to_unix()}",
      content: content,
      metadata: %{
        "contact_id" => contact_id,
        "contact_email" => contact_email
      },
      created_at_source: DateTime.utc_now()
    })
  end

  defp format_api_error(service, :unauthorized), do: "#{service} authentication expired. Please reconnect."
  defp format_api_error(service, {:rate_limited, _}), do: "#{service} API rate limit reached. Please try again later."
  defp format_api_error(service, {_, %{"error" => %{"message" => msg}}}), do: "#{service} error: #{msg}"
  defp format_api_error(service, {_, %{"message" => msg}}), do: "#{service} error: #{msg}"
  defp format_api_error(service, _), do: "#{service} API error occurred"
end
