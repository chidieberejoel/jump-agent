defmodule JumpAgent.WebhookService do
  @moduledoc """
  Manages webhook registrations for Gmail and Calendar.
  Gmail uses Pub/Sub, Calendar uses direct webhooks.
  """

  alias JumpAgent.{GoogleAPI, HubSpotAPI, HubSpot}
  require Logger

  @gmail_topic "projects/#{Application.get_env(:jump_agent, :google_cloud_project_id)}/topics/gmail-push"

  # Watch duration in seconds (7 days - maximum allowed by Google)
  @watch_duration_seconds 7 * 24 * 60 * 60

  @doc """
  Sets up Gmail push notifications for a user using Pub/Sub.
  """
  def setup_gmail_webhook(user) do
    request_body = %{
      topicName: @gmail_topic,
      labelIds: ["INBOX"],
      labelFilterAction: "include"
    }

    # Stop any existing watch
    GoogleAPI.stop_gmail_watch(user)

    # Start new watch
    case GoogleAPI.gmail_request(user, :post, "/users/me/watch", request_body) do
      {:ok, %{"expiration" => expiration, "historyId" => history_id}} ->
        expiration_dt = expiration
                        |> String.to_integer()
                        |> DateTime.from_unix!(:millisecond)
                        |> DateTime.truncate(:second)

        {:ok, updated_user} = JumpAgent.Accounts.update_user_webhook_info(user, %{
          gmail_watch_expiration: expiration_dt,
          gmail_history_id: to_string(history_id)
        })

        schedule_renewal(updated_user, :gmail, expiration_dt)

        Logger.info("Gmail webhook registered for user #{user.id}, expires: #{expiration_dt}")
        {:ok, expiration_dt}

      {:error, reason} = error ->
        Logger.error("Failed to register Gmail webhook for user #{user.id}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Sets up Calendar push notifications for a user using direct webhooks.
  Calendar API doesn't use Pub/Sub - it sends notifications directly.
  """
  def setup_calendar_webhook(user, calendar_id \\ "primary") do
    # Stop any existing calendar watch first
    stop_calendar_webhook(user)

    webhook_url = webhook_url(:calendar)

    # Generate a unique channel ID for this watch
    channel_id = "calendar-#{user.id}-#{:os.system_time(:second)}"

    # Calculate expiration time (current time + 7 days)
    expiration_ms = System.os_time(:millisecond) + (@watch_duration_seconds * 1000)

    request_body = %{
      id: channel_id,
      type: "web_hook",
      address: webhook_url,
      token: generate_webhook_token(user.id),
      expiration: expiration_ms
    }

    case GoogleAPI.calendar_request(user, :post, "/calendars/#{calendar_id}/events/watch", request_body) do
      {:ok, %{"expiration" => expiration} = response} ->
        expiration_dt = expiration
                        |> String.to_integer()
                        |> DateTime.from_unix!(:millisecond)
                        |> DateTime.truncate(:second)

        # Store channel info for later management
        {:ok, updated_user} = JumpAgent.Accounts.update_user_webhook_info(user, %{
          calendar_watch_expiration: expiration_dt,
          calendar_channel_id: channel_id,
          calendar_resource_id: response["resourceId"]
        })

        schedule_renewal(updated_user, :calendar, expiration_dt)

        Logger.info("Calendar webhook registered for user #{user.id}, expires: #{expiration_dt}")
        {:ok, expiration_dt}

      {:error, reason} = error ->
        Logger.error("Failed to register Calendar webhook for user #{user.id}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Sets up HubSpot webhooks for a connection.
  """
  def setup_hubspot_webhooks(connection) do
    app_id = Application.get_env(:jump_agent, :hubspot_app_id)

    if is_nil(app_id) || app_id == "" do
      Logger.error("HubSpot app ID not configured")
      {:error, :app_id_missing}
    else
      webhook_url = webhook_url(:hubspot)

      subscriptions = [
        %{
          eventType: "contact.creation",
          propertyName: nil,
          active: true
        },
        %{
          eventType: "contact.propertyChange",
          propertyName: "email",
          active: true
        },
        %{
          eventType: "contact.propertyChange",
          propertyName: "firstname",
          active: true
        },
        %{
          eventType: "contact.propertyChange",
          propertyName: "lastname",
          active: true
        },
        %{
          eventType: "contact.deletion",
          propertyName: nil,
          active: true
        }
      ]

      settings = %{
        targetUrl: webhook_url,
        throttling: %{
          period: "SECONDLY",
          maxConcurrentRequests: 10
        }
      }

      case update_hubspot_webhook_settings(connection, app_id, settings, subscriptions) do
        {:ok, _} ->
          Logger.info("HubSpot webhooks configured for connection #{connection.id}")
          {:ok, :configured}

        {:error, :not_found} ->
          create_hubspot_webhook_settings(connection, app_id, settings, subscriptions)

        error ->
          error
      end
    end
  end

  @doc """
  Stops Gmail push notifications for a user.
  """
  def stop_gmail_webhook(user) do
    case GoogleAPI.gmail_request(user, :post, "/users/me/stop", %{}) do
      {:ok, _} ->
        JumpAgent.Accounts.update_user_webhook_info(user, %{
          gmail_watch_expiration: nil,
          gmail_history_id: nil
        })
        Logger.info("Gmail webhook stopped for user #{user.id}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to stop Gmail webhook for user #{user.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Stops Calendar push notifications for a user.
  """
  def stop_calendar_webhook(user) do
    if user.calendar_channel_id && user.calendar_resource_id do
      request_body = %{
        id: user.calendar_channel_id,
        resourceId: user.calendar_resource_id
      }

      case GoogleAPI.calendar_request(user, :post, "/channels/stop", request_body) do
        {:ok, _} ->
          JumpAgent.Accounts.update_user_webhook_info(user, %{
            calendar_watch_expiration: nil,
            calendar_channel_id: nil,
            calendar_resource_id: nil
          })
          Logger.info("Calendar webhook stopped for user #{user.id}")
          :ok

        {:error, %{status: 404}} ->
          # Channel doesn't exist on Google's side, just clear local data
          JumpAgent.Accounts.update_user_webhook_info(user, %{
            calendar_watch_expiration: nil,
            calendar_channel_id: nil,
            calendar_resource_id: nil
          })
          Logger.info("Calendar webhook not found on Google, cleared local data for user #{user.id}")
          :ok

        {:error, reason} ->
          Logger.error("Failed to stop Calendar webhook for user #{user.id}: #{inspect(reason)}")
          # Clear local data anyway to avoid stuck state
          JumpAgent.Accounts.update_user_webhook_info(user, %{
            calendar_watch_expiration: nil,
            calendar_channel_id: nil,
            calendar_resource_id: nil
          })
          {:error, reason}
      end
    else
      :ok
    end
  end

  @doc """
  Renews expiring webhooks.
  """
  def renew_expiring_webhooks do
    # Check Gmail webhooks expiring in next 24 hours
    JumpAgent.Accounts.list_users_with_expiring_gmail_watch(hours: 24)
    |> Enum.each(&setup_gmail_webhook/1)

    # Check Calendar webhooks expiring in next 24 hours
    JumpAgent.Accounts.list_users_with_expiring_calendar_watch(hours: 24)
    |> Enum.each(&setup_calendar_webhook/1)
  end

  # Private functions

  defp webhook_url(service) do
    base_url = Application.get_env(:jump_agent, :webhook_base_url) ||
      JumpAgentWeb.Endpoint.url()

    case service do
      :gmail -> "#{base_url}/api/webhooks/gmail"
      :calendar -> "#{base_url}/api/webhooks/calendar"
      :hubspot -> "#{base_url}/api/webhooks/hubspot"
    end
  end

  defp generate_webhook_token(user_id) do
    # Generate a secure token for webhook verification
    secret = webhook_secret()
    :crypto.mac(:hmac, :sha256, secret, "#{user_id}")
    |> Base.encode64(padding: false)
  end

  defp webhook_secret do
    Application.get_env(:jump_agent, :webhook_secret) ||
      raise "Webhook secret not configured"
  end

  defp schedule_renewal(user, service, expiration_dt) do
    # Schedule renewal 6 hours before expiration
    renewal_time = DateTime.add(expiration_dt, -6 * 60 * 60, :second)

    %{user_id: user.id, service: service}
    |> JumpAgent.Workers.WebhookRenewalWorker.new(scheduled_at: renewal_time)
    |> Oban.insert()
  end

  defp create_hubspot_webhook_settings(connection, app_id, settings, subscriptions) do
    body = Map.put(settings, :subscriptions, subscriptions)

    case HubSpotAPI.create_webhook_settings(connection, app_id, body) do
      {:ok, response} ->
        Logger.info("HubSpot webhook settings created")
        {:ok, response}

      {:error, reason} = error ->
        Logger.error("Failed to create HubSpot webhook settings: #{inspect(reason)}")
        error
    end
  end

  defp update_hubspot_webhook_settings(connection, app_id, settings, subscriptions) do
    case HubSpotAPI.get_webhook_settings(connection, app_id) do
      {:ok, _current} ->
        body = Map.put(settings, :subscriptions, subscriptions)

        case HubSpotAPI.update_webhook_settings(connection, app_id, body) do
          {:ok, response} ->
            {:ok, response}

          error ->
            error
        end

      {:error, :not_found} ->
        {:error, :not_found}

      error ->
        error
    end
  end
end
