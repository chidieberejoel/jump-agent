defmodule JumpAgentWeb.WebhookController do
  use JumpAgentWeb, :controller

  alias JumpAgent.{AI, Accounts, HubSpot}
  require Logger

  # Gmail Push Notification (via Pub/Sub)
  def gmail(conn, params) do
    # Gmail notifications come from Pub/Sub
    if verify_pubsub_message(conn, params) do
      handle_gmail_notification(params)

      conn
      |> put_status(:ok)
      |> text("")
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized"})
    end
  end

  # Google Calendar Push Notification (direct webhook)
  def calendar(conn, params) do
    # Calendar sends direct webhooks with specific headers
    if verify_calendar_webhook(conn) do
      handle_calendar_notification(conn, params)

      conn
      |> put_status(:ok)
      |> text("")
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized"})
    end
  end

  # HubSpot Webhook
  def hubspot(conn, params) do
    if verify_hubspot_signature(conn) do
      handle_hubspot_events(params)

      conn
      |> put_status(:ok)
      |> json(%{status: "ok"})
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized"})
    end
  end

  defp verify_pubsub_message(conn, params) do
    # Pub/Sub messages come with a specific structure
    case params do
      %{"message" => %{"data" => _data}} ->
        # Verify the request comes from Google's IPs
        user_agent = get_req_header(conn, "user-agent") |> List.first() || ""
        String.contains?(user_agent, "Google-Cloud-PubSub")

      _ ->
        false
    end
  end

  defp verify_calendar_webhook(conn) do
    # Calendar webhooks include specific headers
    channel_id = get_req_header(conn, "x-goog-channel-id") |> List.first()
    resource_id = get_req_header(conn, "x-goog-resource-id") |> List.first()

    # Verify headers are present
    channel_id && resource_id
  end

  defp verify_hubspot_signature(conn) do
    signature = get_req_header(conn, "x-hubspot-signature") |> List.first()

    if signature do
      # Verify signature
      app_secret = Application.get_env(:jump_agent, :hubspot_client_secret)
      request_body = conn.assigns[:raw_body] || ""

      expected_signature = :crypto.mac(:hmac, :sha256, app_secret, request_body) |> Base.encode16(case: :lower)

      Plug.Crypto.secure_compare(signature, expected_signature)
    else
      false
    end
  end

  defp handle_gmail_notification(%{"message" => %{"data" => encoded_data}}) do
    # Decode the Pub/Sub message
    case Base.decode64(encoded_data) do
      {:ok, decoded} ->
        data = Jason.decode!(decoded)
        email = data["emailAddress"]
        history_id = data["historyId"]

        Logger.info("Gmail notification for #{email}, history ID: #{history_id}")

        # Find user and sync their Gmail
        case Accounts.get_user_by_email(email) do
          nil ->
            Logger.warning("No user found for email: #{email}")

          user ->
            # Queue Gmail sync job
            %{user_id: user.id, history_id: history_id}
            |> JumpAgent.Workers.GmailSyncWorker.new()
            |> Oban.insert()
        end

      {:error, _} ->
        Logger.error("Failed to decode Gmail notification")
    end
  end

  defp handle_calendar_notification(conn, _params) do
    # Get notification details from headers
    channel_id = get_req_header(conn, "x-goog-channel-id") |> List.first()
    resource_id = get_req_header(conn, "x-goog-resource-id") |> List.first()
    resource_state = get_req_header(conn, "x-goog-resource-state") |> List.first()

    Logger.info("Calendar notification - Channel: #{channel_id}, State: #{resource_state}")

    # Find user by channel ID
    case Accounts.get_user_by_calendar_channel_id(channel_id) do
      nil ->
        Logger.warning("No user found for channel ID: #{channel_id}")

      user ->
        # Only process if not a sync message
        if resource_state != "sync" do
          # Queue calendar sync job with webhook flag
          %{user_id: user.id, webhook_notification: true}
          |> JumpAgent.Workers.CalendarSyncWorker.new()
          |> Oban.insert()
        end
    end
  end

  defp handle_hubspot_events(params) do
    # Process each HubSpot event
    Enum.each(params, fn event ->
      %{
        "eventType" => event_type,
        "objectId" => object_id,
        "propertyName" => property_name,
        "propertyValue" => property_value
      } = event

      Logger.info("HubSpot event: #{event_type} for object #{object_id}")

      # Queue appropriate sync job based on event type
      case event_type do
        "contact" <> _ ->
          %{object_id: object_id, event_type: event_type}
          |> JumpAgent.Workers.HubSpotContactSyncWorker.new()
          |> Oban.insert()

        _ ->
          Logger.debug("Unhandled HubSpot event type: #{event_type}")
      end
    end)
  end

  defp get_peer_ip(conn) do
    forwarded_for = get_req_header(conn, "x-forwarded-for") |> List.first()

    if forwarded_for do
      forwarded_for
      |> String.split(",")
      |> List.first()
      |> String.trim()
    else
      to_string(:inet.ntoa(conn.remote_ip))
    end
  end
end
