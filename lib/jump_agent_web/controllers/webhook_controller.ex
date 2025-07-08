defmodule JumpAgentWeb.WebhookController do
  use JumpAgentWeb, :controller

  alias JumpAgent.{AI, Accounts, HubSpot}
  require Logger

  # Gmail Push Notification
  def gmail(conn, params) do
    # Verify the push notification is from Google
    if verify_google_push(conn) do
      handle_gmail_notification(params)

      conn
      |> put_status(:ok)
      |> json(%{status: "ok"})
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized"})
    end
  end

  # Google Calendar Push Notification
  def calendar(conn, params) do
    if verify_google_push(conn) do
      handle_calendar_notification(params)

      conn
      |> put_status(:ok)
      |> json(%{status: "ok"})
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized"})
    end
  end

  # HubSpot Webhook
  def hubspot(conn, params) do
    # Verify HubSpot webhook signature
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

  # Verification challenge for setting up webhooks
  def verify(conn, %{"hub.mode" => "subscribe", "hub.challenge" => challenge, "hub.verify_token" => token}) do
    expected_token = Application.get_env(:jump_agent, :webhook_verify_token, "jump_agent_webhook_token")

    if token == expected_token do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, challenge)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Invalid verify token"})
    end
  end

  def verify(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Invalid verification request"})
  end

  # Private functions

  defp verify_google_push(conn) do
    # Verify the push notification came from Google
    # Check for Google's User-Agent and source IPs
    user_agent = get_req_header(conn, "user-agent") |> List.first() || ""
    source_ip = get_peer_ip(conn)

    # Google Push notifications come from specific IPs and user agents
    valid_user_agent = String.contains?(user_agent, "Google-Cloud-Pub/Sub")

    # In production, also verify against Google's IP ranges
    # For now, check user agent at minimum
    if Application.get_env(:jump_agent, :env) == :prod do
      valid_user_agent
    else
      true
    end
  end

  defp verify_hubspot_signature(conn) do
    # Verify HubSpot webhook signature
    # https://developers.hubspot.com/docs/api/webhooks/validating-requests
    signature = get_req_header(conn, "x-hubspot-signature") |> List.first()

    if signature && Application.get_env(:jump_agent, :env) == :prod do
      # Get the raw body
      {:ok, body, _conn} = Plug.Conn.read_body(conn)

      client_secret = Application.get_env(:jump_agent, :hubspot_client_secret)
      expected_signature = :crypto.mac(:hmac, :sha256, client_secret, body) |> Base.encode16(case: :lower)

      Plug.Crypto.secure_compare(signature, "sha256=#{expected_signature}")
    else
      true
    end
  end

  defp get_peer_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] -> forwarded |> String.split(",") |> List.first() |> String.trim()
      [] -> to_string(:inet_parse.ntoa(conn.remote_ip))
    end
  end

  defp handle_gmail_notification(%{"message" => message}) do
    # Decode the Pub/Sub message
    case Base.decode64(message["data"] || "") do
      {:ok, decoded} ->
        data = Jason.decode!(decoded)
        user_email = data["emailAddress"]

        # Find user by email
        case Accounts.get_user_by_email(user_email) do
          nil ->
            Logger.warning("Gmail notification for unknown user: #{user_email}")

          user ->
            # Queue a sync for this user
            %{user_id: user.id}
            |> JumpAgent.Workers.GmailSyncWorker.new()
            |> Oban.insert()

            # Process event for instructions
            AI.process_external_event(user, "email_received", data)
        end

      _ ->
        Logger.error("Failed to decode Gmail push notification")
    end
  end

  defp handle_calendar_notification(%{"message" => message}) do
    # Similar to Gmail
    case Base.decode64(message["data"] || "") do
      {:ok, decoded} ->
        data = Jason.decode!(decoded)

        # Calendar notifications include the resource ID
        # We'd need to map this to a user
        # For now, process all users' calendars
        Logger.info("Calendar notification received: #{inspect(data)}")

      # Queue calendar sync for affected users
      # This would be more targeted in production

      _ ->
        Logger.error("Failed to decode Calendar push notification")
    end
  end

  defp handle_hubspot_events(params) do
    # HubSpot sends webhook events in batches
    events = params["events"] || [params]

    Enum.each(events, fn event ->
      handle_hubspot_event(event)
    end)
  end

  defp handle_hubspot_event(event) do
    portal_id = to_string(event["portalId"])
    object_type = event["subscriptionType"]

    # Find the HubSpot connection
    case HubSpot.get_connection_by_portal_id(portal_id) do
      nil ->
        Logger.warning("HubSpot event for unknown portal: #{portal_id}")

      connection ->
        user = HubSpot.get_connection_user(connection)

        # Map HubSpot event types to our trigger types
        trigger_type = map_hubspot_event_type(object_type)

        if trigger_type do
          AI.process_external_event(user, trigger_type, event)

          # Queue a sync for this specific object
          queue_hubspot_sync(connection, event)
        end
    end
  end

  defp map_hubspot_event_type("contact.creation"), do: "hubspot_contact_created"
  defp map_hubspot_event_type("contact.propertyChange"), do: "hubspot_contact_updated"
  defp map_hubspot_event_type("contact.deletion"), do: "hubspot_contact_deleted"
  defp map_hubspot_event_type(_), do: nil

  defp queue_hubspot_sync(connection, event) do
    # Queue a targeted sync based on the event type
    %{
      connection_id: connection.id,
      object_type: event["subscriptionType"],
      object_id: event["objectId"]
    }
    |> JumpAgent.Workers.HubSpotSyncWorker.new()
    |> Oban.insert()
  end
end
