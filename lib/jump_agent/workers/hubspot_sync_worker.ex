defmodule JumpAgent.Workers.HubSpotSyncWorker do
  @moduledoc """
  Syncs contacts and notes from HubSpot, creates embeddings for RAG, and triggers instruction processing.
  """

  use Oban.Worker, queue: :sync

  alias JumpAgent.{HubSpot, HubSpotAPI, AI}
  alias JumpAgent.AI.EmbeddingService
  require Logger

  @impl Oban.Worker
  def perform(_job) do
    # Get all HubSpot connections
    connections = HubSpot.list_all_connections()

    Enum.each(connections, &sync_connection/1)

    :ok
  end

  defp sync_connection(connection) do
    Logger.info("Syncing HubSpot for connection #{connection.id}")

    # Sync contacts
    sync_contacts(connection)

    # Sync recent notes/engagements
    sync_engagements(connection)
  rescue
    error ->
      Logger.error("HubSpot sync error for connection #{connection.id}: #{inspect(error)}")
  end

  defp sync_contacts(connection) do
    case HubSpotAPI.list_contacts(connection, limit: 100) do
      {:ok, %{"results" => contacts}} ->
        process_contacts(connection, contacts)

      {:error, :unauthorized} ->
        Logger.warning("HubSpot sync failed for connection #{connection.id}: unauthorized")

      {:error, reason} ->
        Logger.error("HubSpot contact sync failed: #{inspect(reason)}")
    end
  end

  defp process_contacts(connection, contacts) do
    user = HubSpot.get_connection_user(connection)

    Enum.each(contacts, fn contact ->
      # Check if this contact already has an embedding
      existing_embedding = AI.VectorSearch.find_by_source(user.id, "hubspot_contact", contact["id"])
      is_new_contact = is_nil(existing_embedding)

      # Always create/update embedding
      create_contact_embedding(user, contact)

      # Trigger instructions for new contacts
      if is_new_contact do
        trigger_contact_instructions(user, contact, "hubspot_contact_created")
      else
        # For existing contacts, check if it was updated recently
        if recently_updated?(contact) do
          trigger_contact_instructions(user, contact, "hubspot_contact_updated")
        end
      end
    end)
  end

  defp trigger_contact_instructions(user, contact, event_type) do
    props = contact["properties"] || %{}

    # Extract contact data for instruction processing
    contact_data = %{
      "contact_id" => contact["id"],
      "email" => props["email"],
      "first_name" => props["firstname"],
      "last_name" => props["lastname"],
      "full_name" => build_full_name(props),
      "company" => props["company"],
      "phone" => props["phone"],
      "job_title" => props["jobtitle"],
      "lifecycle_stage" => props["lifecyclestage"],
      "created_at" => contact["createdAt"],
      "updated_at" => contact["updatedAt"],
      "properties" => props
    }

    # Process external event to trigger any matching instructions
    Logger.info("Processing #{event_type} for instruction triggers")
    AI.process_external_event(user, event_type, contact_data)
  end

  defp create_contact_embedding(user, contact) do
    props = contact["properties"] || %{}

    # Build content from contact properties
    content_parts = [
                      props["firstname"],
                      props["lastname"],
                      props["email"],
                      props["company"],
                      props["phone"],
                      props["jobtitle"],
                      props["notes"]
                    ]
                    |> Enum.reject(&is_nil/1)
                    |> Enum.join(" ")

    if content_parts != "" do
      prepared_content = EmbeddingService.prepare_content(content_parts, %{
        "name" => "#{props["firstname"]} #{props["lastname"]}",
        "email" => props["email"],
        "company" => props["company"],
        "lifecycle_stage" => props["lifecyclestage"]
      })

      case AI.upsert_document_embedding(user, %{
        source_type: "hubspot_contact",
        source_id: contact["id"],
        content: prepared_content,
        metadata: props,
        created_at_source: parse_hubspot_date(contact["createdAt"])
      }) do
        {:ok, _embedding} ->
          Logger.debug("Created embedding for HubSpot contact #{contact["id"]}")
        {:error, reason} ->
          Logger.warning("Failed to create embedding for HubSpot contact #{contact["id"]}: #{inspect(reason)}")
      end
    end
  end

  defp sync_engagements(connection) do
    # Sync email engagements (notes)
    case HubSpotAPI.list_sales_emails(connection, limit: 50) do
      {:ok, %{"results" => engagements}} ->
        process_engagements(connection, engagements)

      {:error, reason} ->
        Logger.error("HubSpot engagement sync failed: #{inspect(reason)}")
    end
  end

  defp process_engagements(connection, engagements) do
    user = HubSpot.get_connection_user(connection)

    # Filter for notes
    notes = Enum.filter(engagements, fn eng ->
      eng["engagement"]["type"] == "NOTE"
    end)

    Enum.each(notes, fn note ->
      create_note_embedding(user, note)
    end)
  end

  defp create_note_embedding(user, engagement) do
    metadata = engagement["metadata"] || %{}
    associations = engagement["associations"] || %{}

    if metadata["body"] do
      contact_ids = associations["contactIds"] || []

      prepared_content = EmbeddingService.prepare_content(
        metadata["body"],
        %{
          "contact_ids" => Enum.join(contact_ids, ", "),
          "created_at" => engagement["engagement"]["createdAt"]
        }
      )

      case AI.upsert_document_embedding(user, %{
        source_type: "hubspot_note",
        source_id: to_string(engagement["engagement"]["id"]),
        content: prepared_content,
        metadata: %{
          "contact_ids" => contact_ids,
          "subject" => metadata["subject"]
        },
        created_at_source: parse_hubspot_date(engagement["engagement"]["createdAt"])
      }) do
        {:ok, _embedding} ->
          Logger.debug("Created embedding for HubSpot note #{engagement["engagement"]["id"]}")
        {:error, reason} ->
          Logger.warning("Failed to create embedding for HubSpot note #{engagement["engagement"]["id"]}: #{inspect(reason)}")
      end
    end
  end

  defp build_full_name(props) do
    [props["firstname"], props["lastname"]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.trim()
  end

  defp parse_hubspot_date(timestamp) when is_integer(timestamp) do
    DateTime.from_unix!(timestamp, :millisecond)
  end
  defp parse_hubspot_date(date_string) when is_binary(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, datetime, _} -> datetime
      _ -> DateTime.utc_now()
    end
  end
  defp parse_hubspot_date(_), do: DateTime.utc_now()

  defp recently_updated?(contact) do
    # Consider a contact recently updated if it was modified in the last hour
    case contact["updatedAt"] do
      nil -> false
      updated_at ->
        updated_datetime = parse_hubspot_date(updated_at)
        threshold = DateTime.add(DateTime.utc_now(), -3600, :second) # 1 hour ago
        DateTime.compare(updated_datetime, threshold) == :gt
    end
  end
end
