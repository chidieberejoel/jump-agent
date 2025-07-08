defmodule JumpAgent.AI.ToolExecutor do
  @moduledoc """
  Executes AI tools by calling the appropriate APIs.
  """

  alias JumpAgent.{GoogleAPI, HubSpotAPI, HubSpot, AI}
  alias JumpAgent.AI.VectorSearch
  require Logger

  @doc """
  Executes a tool with the given parameters.
  """
  def execute(tool_type, user, params) do
    # Validate parameters first
    case JumpAgent.AI.ToolValidator.validate(tool_type, params) do
      {:ok, validated_params} ->
        do_execute(tool_type, user, validated_params)
      {:error, validation_error} ->
        {:error, {:validation_error, validation_error}}
    end
  end

  defp do_execute("search_information", user, params) do
    query = params["query"]
    source_types = params["source_types"]

    results = AI.search_similar_documents(user, query,
      limit: 20,
      source_types: source_types
    )

    {:ok, %{
      "results" => Enum.map(results, &format_search_result/1),
      "total" => length(results)
    }}
  end

  defp do_execute("send_email", user, params) do
    # Build email message
    message = build_email_message(params)

    case GoogleAPI.send_email(user, message) do
      {:ok, %{"id" => message_id}} ->
        {:ok, %{"message_id" => message_id, "status" => "sent"}}
      {:error, reason} ->
        {:error, {:api_error, format_google_error(reason)}}
    end
  end

  defp do_execute("create_calendar_event", user, params) do
    event = build_calendar_event(params)

    case GoogleAPI.create_calendar_event(user, event) do
      {:ok, %{"id" => event_id} = response} ->
        {:ok, %{
          "event_id" => event_id,
          "html_link" => response["htmlLink"],
          "status" => "created"
        }}
      {:error, reason} ->
        {:error, {:api_error, format_google_error(reason)}}
    end
  end

  defp do_execute("create_contact", user, params) do
    connection = HubSpot.get_connection_by_user(user)

    if connection do
      properties = build_contact_properties(params)

      case HubSpotAPI.create_contact(connection, properties) do
        {:ok, %{"id" => contact_id} = response} ->
          # Create embedding for the new contact
          create_contact_embedding(user, response)

          {:ok, %{"contact_id" => contact_id, "status" => "created"}}
        {:error, reason} ->
          {:error, {:api_error, format_hubspot_error(reason)}}
      end
    else
      {:error, "HubSpot not connected"}
    end
  end

  defp do_execute("update_contact", user, params) do
    connection = HubSpot.get_connection_by_user(user)

    if connection do
      email = params["email"]
      properties = params["properties"]

      # First, find the contact
      case find_contact_by_email(connection, email) do
        {:ok, contact_id} ->
          case HubSpotAPI.update_contact(connection, contact_id, properties) do
            {:ok, response} ->
              # Update embedding
              update_contact_embedding(user, contact_id, response)

              {:ok, %{"contact_id" => contact_id, "status" => "updated"}}
            {:error, reason} ->
              {:error, {:api_error, format_hubspot_error(reason)}}
          end
        {:error, :not_found} ->
          {:error, "Contact not found with email: #{email}"}
        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "HubSpot not connected"}
    end
  end

  defp do_execute("add_hubspot_note", user, params) do
    connection = HubSpot.get_connection_by_user(user)

    if connection do
      email = params["contact_email"]
      note_content = params["note_content"]

      # Find the contact
      case find_contact_by_email(connection, email) do
        {:ok, contact_id} ->
          # Create engagement (note)
          engagement = build_note_engagement(contact_id, note_content)

          case HubSpotAPI.create_engagement(connection, engagement) do
            {:ok, %{"engagement" => %{"id" => note_id}}} ->
              # Create embedding for the note
              create_note_embedding(user, contact_id, email, note_content)

              {:ok, %{"note_id" => note_id, "contact_id" => contact_id, "status" => "created"}}
            {:error, reason} ->
              {:error, {:api_error, format_hubspot_error(reason)}}
          end
        {:error, :not_found} ->
          {:error, "Contact not found with email: #{email}"}
        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "HubSpot not connected"}
    end
  end

  defp do_execute("schedule_meeting", user, params) do
    # This is a complex multi-step process
    contact_email = params["contact_email"]
    meeting_title = params["meeting_title"]
    duration = params["duration_minutes"] || 30

    # Find available slots if not provided
    available_times =
      if params["preferred_times"] do
        params["preferred_times"]
      else
        find_available_calendar_slots(user, duration)
      end

    # Compose and send scheduling email
    email_body = build_scheduling_email(meeting_title, available_times, params["message"])

    email_params = %{
      "to" => contact_email,
      "subject" => "Meeting Request: #{meeting_title}",
      "body" => email_body
    }

    case do_execute("send_email", user, email_params) do
      {:ok, result} ->
        # Return waiting status - will need to monitor for response
        {:waiting, %{
          "wait_type" => "email_response",
          "wait_for_email" => contact_email,
          "meeting_details" => %{
            "title" => meeting_title,
            "duration" => duration,
            "available_times" => available_times
          },
          "email_message_id" => result["message_id"],
          "wait_minutes" => 1440 # Check again in 24 hours
        }}
      error ->
        error
    end
  end

  defp do_execute(tool_type, _user, _params) do
    {:error, "Unknown tool type: #{tool_type}"}
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

  defp build_email_message(params) do
    %{
      to: params["to"],
      subject: params["subject"],
      body: params["body"],
      cc: params["cc"],
      bcc: params["bcc"]
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp build_calendar_event(params) do
    %{
      summary: params["title"],
      start: %{dateTime: params["start_time"], timeZone: "UTC"},
      end: %{dateTime: params["end_time"], timeZone: "UTC"},
      description: params["description"],
      location: params["location"],
      attendees: build_attendees(params["attendees"])
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp build_attendees(nil), do: nil
  defp build_attendees(emails) when is_list(emails) do
    Enum.map(emails, &%{email: &1})
  end

  defp build_contact_properties(params) do
    %{
      "email" => params["email"],
      "firstname" => params["first_name"],
      "lastname" => params["last_name"],
      "company" => params["company"],
      "phone" => params["phone"]
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
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

  defp build_note_engagement(contact_id, note_content) do
    %{
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
  end

  defp find_available_calendar_slots(user, duration_minutes) do
    # Get calendar events for the next 2 weeks
    start_time = DateTime.utc_now()
    end_time = DateTime.add(start_time, 14, :day)

    case GoogleAPI.list_calendar_events(user, "primary", %{
      timeMin: DateTime.to_iso8601(start_time),
      timeMax: DateTime.to_iso8601(end_time),
      singleEvents: true,
      orderBy: "startTime"
    }) do
      {:ok, %{"items" => events}} ->
        # Find available slots (simplified - in production, this would be more sophisticated)
        # For now, just suggest some times during business hours
        generate_available_slots(duration_minutes)
      _ ->
        generate_available_slots(duration_minutes)
    end
  end

  defp generate_available_slots(duration_minutes) do
    # Generate some available slots for the next few days
    today = Date.utc_today()

    Enum.flat_map(1..5, fn day_offset ->
      date = Date.add(today, day_offset)

      # Suggest morning and afternoon slots
      [
        %{"date" => Date.to_string(date), "time" => "09:00"},
        %{"date" => Date.to_string(date), "time" => "14:00"},
        %{"date" => Date.to_string(date), "time" => "16:00"}
      ]
    end)
    |> Enum.take(6)
  end

  defp build_scheduling_email(meeting_title, available_times, additional_message) do
    times_text =
      available_times
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
    content = AI.EmbeddingService.prepare_content(
      "#{contact["properties"]["firstname"]} #{contact["properties"]["lastname"]} " <>
      "#{contact["properties"]["email"]} #{contact["properties"]["company"]}",
      %{
        "name" => "#{contact["properties"]["firstname"]} #{contact["properties"]["lastname"]}",
        "email" => contact["properties"]["email"],
        "company" => contact["properties"]["company"]
      }
    )

    AI.upsert_document_embedding(user, %{
      source_type: "hubspot_contact",
      source_id: contact["id"],
      content: content,
      metadata: contact["properties"],
      created_at_source: contact["createdAt"]
    })
  end

  defp update_contact_embedding(user, contact_id, updated_contact) do
    # Fetch full contact details
    connection = HubSpot.get_connection_by_user(user)

    case HubSpotAPI.get_contact(connection, contact_id) do
      {:ok, contact} ->
        create_contact_embedding(user, contact)
      _ ->
        :ok
    end
  end

  defp create_note_embedding(user, contact_id, contact_email, note_content) do
    content = AI.EmbeddingService.prepare_content(
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

  defp format_google_error(:unauthorized), do: "Google authentication expired"
  defp format_google_error({:rate_limited, _}), do: "Google API rate limit reached"
  defp format_google_error({_, %{"error" => %{"message" => msg}}}), do: msg
  defp format_google_error(_), do: "Google API error"

  defp format_hubspot_error(:unauthorized), do: "HubSpot authentication expired"
  defp format_hubspot_error({:rate_limited, _}), do: "HubSpot API rate limit reached"
  defp format_hubspot_error({_, %{"message" => msg}}), do: msg
  defp format_hubspot_error(_), do: "HubSpot API error"
end
