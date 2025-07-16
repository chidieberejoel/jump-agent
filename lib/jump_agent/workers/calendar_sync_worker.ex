defmodule JumpAgent.Workers.CalendarSyncWorker do
  @moduledoc """
  Syncs calendar events from Google Calendar and triggers instruction processing.
  """

  use Oban.Worker, queue: :sync

  alias JumpAgent.{Accounts, GoogleAPI, AI}
  alias JumpAgent.AI.EmbeddingService
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case Accounts.get_user(user_id) do
      nil ->
        Logger.warning("User not found: #{user_id}")
        :ok

      user ->
        sync_user_calendars(user)
    end
  end

  def perform(_job) do
    # Get all users with Google tokens
    users = Accounts.list_users_with_google_tokens()

    Enum.each(users, &sync_user_calendars/1)

    :ok
  end

  defp sync_user_calendars(user) do
    Logger.info("Syncing calendars for user #{user.id}")

    # Get primary calendar events
    sync_calendar_events(user, "primary")
  rescue
    error ->
      Logger.error("Calendar sync error for user #{user.id}: #{inspect(error)}")
  end

  defp sync_calendar_events(user, calendar_id) do
    # Get events for the next 30 days
    now = DateTime.utc_now()
    time_min = DateTime.to_iso8601(now)
    time_max = now |> DateTime.add(30, :day) |> DateTime.to_iso8601()

    opts = [
      timeMin: time_min,
      timeMax: time_max,
      singleEvents: true,
      orderBy: "startTime",
      maxResults: 250
    ]

    case GoogleAPI.list_calendar_events(user, calendar_id, opts) do
      {:ok, %{"items" => events}} when is_list(events) ->
        Enum.each(events, fn event ->
          process_calendar_event(user, event)
        end)

      {:error, :unauthorized} ->
        Logger.warning("Calendar sync failed for user #{user.id}: unauthorized")

      {:error, reason} ->
        Logger.error("Calendar sync failed for user #{user.id}: #{inspect(reason)}")
    end
  end

  defp process_calendar_event(user, event) do
    event_id = event["id"]

    # Check if this is a new event by looking for existing embedding
    existing = AI.VectorSearch.find_by_source(user.id, "calendar", event_id)
    is_new_event = is_nil(existing)

    # Always update or create the embedding
    create_event_embedding(user, event)

    # Trigger instructions only for new events
    if is_new_event && not cancelled?(event) do
      trigger_calendar_instructions(user, event)
    end
  end

  defp trigger_calendar_instructions(user, event) do
    # Extract event data for instruction processing
    event_data = %{
      "event_id" => event["id"],
      "summary" => event["summary"] || "(No Title)",
      "description" => event["description"],
      "location" => event["location"],
      "start" => extract_datetime(event["start"]),
      "end" => extract_datetime(event["end"]),
      "attendees" => extract_attendees(event),
      "organizer" => extract_organizer(event),
      "status" => event["status"],
      "created" => event["created"],
      "updated" => event["updated"],
      "html_link" => event["htmlLink"],
      "is_recurring" => event["recurringEventId"] != nil,
      "is_all_day" => is_all_day_event?(event)
    }

    # Process external event to trigger any matching instructions
    Logger.info("Processing calendar_event_created for instruction triggers")
    AI.process_external_event(user, "calendar_event_created", event_data)
  end

  defp create_event_embedding(user, event) do
    # Build content from event data
    content = build_event_content(event)
    metadata = extract_event_metadata(event)

    if is_binary(content) && String.trim(content) != "" do
      prepared_content = EmbeddingService.prepare_content(content, metadata)

      case AI.upsert_document_embedding(user, %{
        source_type: "calendar",
        source_id: event["id"],
        content: prepared_content,
        metadata: metadata,
        created_at_source: parse_event_date(event["created"])
      }) do
        {:ok, _embedding} ->
          Logger.debug("Created embedding for calendar event #{event["id"]}")
        {:error, reason} ->
          Logger.warning("Failed to create embedding for calendar event #{event["id"]}: #{inspect(reason)}")
      end
    end
  end

  defp build_event_content(event) do
    parts = [
      event["summary"],
      event["description"],
      event["location"],
      format_attendees_text(event["attendees"])
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.trim()
  end

  defp extract_event_metadata(event) do
    %{
      "title" => event["summary"] || "(No Title)",
      "description" => truncate_string(event["description"], 500),
      "date" => format_event_date(event["start"]),
      "start_time" => format_event_date(event["start"]),
      "end_time" => format_event_date(event["end"]),
      "location" => event["location"],
      "organizer" => extract_organizer_email(event),
      "attendee_count" => length(event["attendees"] || []),
      "status" => event["status"],
      "is_recurring" => event["recurringEventId"] != nil
    }
  end

  defp extract_datetime(nil), do: nil
  defp extract_datetime(%{"dateTime" => datetime}), do: datetime
  defp extract_datetime(%{"date" => date}), do: date
  defp extract_datetime(_), do: nil

  defp extract_attendees(event) do
    attendees = event["attendees"] || []

    Enum.map(attendees, fn attendee ->
      %{
        "email" => attendee["email"],
        "display_name" => attendee["displayName"],
        "response_status" => attendee["responseStatus"],
        "organizer" => attendee["organizer"] || false,
        "self" => attendee["self"] || false
      }
    end)
  end

  defp extract_organizer(event) do
    organizer = event["organizer"] || %{}

    %{
      "email" => organizer["email"],
      "display_name" => organizer["displayName"],
      "self" => organizer["self"] || false
    }
  end

  defp extract_organizer_email(event) do
    case event["organizer"] do
      %{"email" => email} -> email
      _ -> nil
    end
  end

  defp format_attendees_text(nil), do: nil
  defp format_attendees_text([]), do: nil
  defp format_attendees_text(attendees) do
    attendees
    |> Enum.map(fn a -> a["email"] || a["displayName"] end)
    |> Enum.filter(&(&1))
    |> Enum.join(", ")
  end

  defp format_event_date(%{"dateTime" => datetime}) do
    format_datetime(datetime)
  end
  defp format_event_date(%{"date" => date}), do: date
  defp format_event_date(_), do: nil

  defp format_datetime(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _} ->
        Timex.format!(datetime, "%B %d, %Y at %I:%M %p", :strftime)
      _ ->
        datetime_string
    end
  end

  defp parse_event_date(created) when is_binary(created) do
    case DateTime.from_iso8601(created) do
      {:ok, datetime, _} -> datetime
      _ -> DateTime.utc_now()
    end
  end

  defp truncate_string(nil, _), do: nil
  defp truncate_string(str, max_length) do
    if String.length(str) > max_length do
      String.slice(str, 0, max_length) <> "..."
    else
      str
    end
  end

  defp cancelled?(event) do
    event["status"] == "cancelled"
  end

  defp is_all_day_event?(event) do
    case event["start"] do
      %{"date" => _date} -> true
      _ -> false
    end
  end
end
