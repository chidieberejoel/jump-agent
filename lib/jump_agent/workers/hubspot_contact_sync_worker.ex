defmodule JumpAgent.Workers.HubSpotContactSyncWorker do
  @moduledoc """
  Processes specific HubSpot contact events from webhooks and triggers instruction processing.
  """

  use Oban.Worker, queue: :webhooks

  alias JumpAgent.{HubSpot, HubSpotAPI, AI}
  alias JumpAgent.AI.EmbeddingService
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"object_id" => object_id, "event_type" => event_type}}) do
    Logger.info("Processing HubSpot webhook event: #{event_type} for contact #{object_id}")

    # Find the connection for this contact
    # In production, you'd want to track which portal/connection the webhook came from
    connections = HubSpot.list_all_connections()

    # Try each connection until we find the contact
    Enum.find_value(connections, fn connection ->
      case process_contact_event(connection, object_id, event_type) do
        :ok -> :ok
        :not_found -> nil
        error -> error
      end
    end) || :ok
  end

  defp process_contact_event(connection, contact_id, event_type) do
    user = HubSpot.get_connection_user(connection)

    # Fetch the contact details
    case HubSpotAPI.get_contact(connection, contact_id) do
      {:ok, contact} ->
        # Create/update the embedding
        create_contact_embedding(user, contact)

        # Determine the instruction trigger type
        trigger_type = case event_type do
          "contact.creation" -> "hubspot_contact_created"
          "contact.deletion" -> "hubspot_contact_deleted"
          _ -> "hubspot_contact_updated"
        end

        # Trigger instruction processing
        trigger_contact_instructions(user, contact, trigger_type)

        :ok

      {:error, %{status: 404}} ->
        Logger.debug("Contact #{contact_id} not found in connection #{connection.id}")
        :not_found

      {:error, reason} ->
        Logger.error("Failed to fetch contact #{contact_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp trigger_contact_instructions(user, contact, event_type) do
    props = contact["properties"] || %{}

    # Parse timestamps for temporal checks
    created_at = parse_hubspot_date(contact["createdAt"])
    updated_at = parse_hubspot_date(contact["updatedAt"])

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
      "lead_status" => props["hs_lead_status"],
      "created_at" => created_at,  # DateTime object for temporal check
      "updated_at" => updated_at,  # DateTime object for temporal check
      "created_at_raw" => contact["createdAt"],  # Keep raw value too
      "updated_at_raw" => contact["updatedAt"],  # Keep raw value too
      "owner_id" => props["hubspot_owner_id"],
      "last_activity_date" => props["notes_last_updated"],
      "properties" => props,
      "event_type" => event_type
    }

    # Process external event to trigger any matching instructions
    Logger.info("Processing #{event_type} event for instruction triggers")
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
                      props["notes"],
                      props["hs_lead_status"],
                      props["lifecyclestage"]
                    ]
                    |> Enum.reject(&is_nil/1)
                    |> Enum.join(" ")

    if content_parts != "" do
      prepared_content = EmbeddingService.prepare_content(content_parts, %{
        "name" => build_full_name(props),
        "email" => props["email"],
        "company" => props["company"],
        "lifecycle_stage" => props["lifecyclestage"],
        "lead_status" => props["hs_lead_status"]
      })

      case AI.upsert_document_embedding(user, %{
        source_type: "hubspot_contact",
        source_id: contact["id"],
        content: prepared_content,
        metadata: props,
        created_at_source: parse_hubspot_date(contact["createdAt"])
      }) do
        {:ok, _embedding} ->
          Logger.debug("Created/updated embedding for HubSpot contact #{contact["id"]}")

        {:error, reason} ->
          Logger.warning("Failed to create embedding for HubSpot contact #{contact["id"]}: #{inspect(reason)}")
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
end
