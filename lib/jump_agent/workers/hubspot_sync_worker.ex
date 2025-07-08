defmodule JumpAgent.Workers.HubSpotSyncWorker do
  @moduledoc """
  Syncs contacts and notes from HubSpot and creates embeddings for RAG.
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
      create_contact_embedding(user, contact)
    end)
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

      AI.upsert_document_embedding(user, %{
        source_type: "hubspot_contact",
        source_id: contact["id"],
        content: prepared_content,
        metadata: props,
        created_at_source: parse_hubspot_date(contact["createdAt"])
      })
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

      AI.upsert_document_embedding(user, %{
        source_type: "hubspot_note",
        source_id: to_string(engagement["engagement"]["id"]),
        content: prepared_content,
        metadata: %{
          "contact_ids" => contact_ids,
          "subject" => metadata["subject"]
        },
        created_at_source: parse_hubspot_date(engagement["engagement"]["createdAt"])
      })
    end
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
