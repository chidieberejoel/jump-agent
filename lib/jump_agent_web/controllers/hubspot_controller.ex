defmodule JumpAgentWeb.HubSpotController do
  use JumpAgentWeb, :controller

  alias JumpAgent.HubSpot
  alias JumpAgent.HubSpotAPI
  require Logger

  @hubspot_auth_url "https://app.hubspot.com/oauth/authorize"
  @required_scopes [
    "crm.objects.contacts.read",
    "crm.objects.contacts.write",
    "crm.objects.owners.read",
    "oauth",
    "timeline",
    "sales-email-read"
  ]

  @optional_scopes []

  def connect(conn, _params) do
    client_id = Application.get_env(:jump_agent, :hubspot_client_id)

    if is_nil(client_id) do
      conn
      |> put_flash(:error, "HubSpot integration is not configured. Please contact support.")
      |> redirect(to: ~p"/dashboard")
    else
      redirect_uri = url(~p"/hubspot/callback")

      # Generate and store state for CSRF protection
      state = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

      # Combine required and optional scopes
      all_scopes = @required_scopes ++ @optional_scopes

      auth_params = %{
        client_id: client_id,
        redirect_uri: redirect_uri,
        scope: Enum.join(all_scopes, " "),
        state: state
      }

      auth_url = "#{@hubspot_auth_url}?#{URI.encode_query(auth_params)}"

      conn
      |> put_session(:hubspot_oauth_state, state)
      |> redirect(external: auth_url)
    end
  end

  def callback(conn, %{"code" => code, "state" => state} = _params) do
    stored_state = get_session(conn, :hubspot_oauth_state)

    # Verify state to prevent CSRF
    if !stored_state || state != stored_state do
      Logger.error("HubSpot OAuth state mismatch - expected: #{inspect(stored_state)}, got: #{inspect(state)}")

      conn
      |> delete_session(:hubspot_oauth_state)
      |> put_flash(:error, "Invalid authentication state. Please try connecting again.")
      |> redirect(to: ~p"/dashboard")
    else
      handle_oauth_callback(conn, code)
    end
  end

  def callback(conn, %{"error" => error} = params) do
    description = Map.get(params, "error_description", "Unknown error")
    Logger.error("HubSpot OAuth error: #{error} - #{description}")

    error_message = case error do
      "access_denied" -> "Access denied. You need to approve the requested permissions."
      "unauthorized_client" -> "This application is not authorized. Please contact support."
      _ -> "HubSpot connection failed: #{description}"
    end

    conn
    |> delete_session(:hubspot_oauth_state)
    |> put_flash(:error, error_message)
    |> redirect(to: ~p"/dashboard")
  end

  def callback(conn, _params) do
    conn
    |> delete_session(:hubspot_oauth_state)
    |> put_flash(:error, "HubSpot connection failed. Missing required parameters.")
    |> redirect(to: ~p"/dashboard")
  end

  def disconnect(conn, _params) do
    user = conn.assigns.current_user

    case HubSpot.get_connection_by_user(user) do
      nil ->
        conn
        |> put_flash(:error, "No HubSpot connection found.")
        |> redirect(to: ~p"/dashboard")

      connection ->
        # Try to revoke the token at HubSpot
        access_token = HubSpot.get_access_token(connection)
        if access_token, do: HubSpotAPI.revoke_token(access_token)

        case HubSpot.delete_connection(connection) do
          {:ok, _} ->
            Logger.info("HubSpot disconnected for user #{user.id}")

            conn
            |> put_flash(:info, "HubSpot account disconnected successfully.")
            |> redirect(to: ~p"/dashboard")

          {:error, reason} ->
            Logger.error("Failed to disconnect HubSpot: #{inspect(reason)}")

            conn
            |> put_flash(:error, "Failed to disconnect HubSpot account. Please try again.")
            |> redirect(to: ~p"/dashboard")
        end
    end
  end

  defp handle_oauth_callback(conn, code) do
    redirect_uri = url(~p"/hubspot/callback")

    case HubSpotAPI.exchange_code_for_token(code, redirect_uri) do
      {:ok, token_data} ->
        user = conn.assigns.current_user

        # Extract token information
        access_token = token_data["access_token"]
        refresh_token = token_data["refresh_token"]
        expires_in = token_data["expires_in"] || 21600
        scopes = @required_scopes

        # Get account info to store portal ID
        temp_connection = %HubSpot.Connection{
          access_token: HubSpot.Connection.encrypt_token(access_token),
          token_expires_at: DateTime.utc_now() |> DateTime.add(expires_in, :second)
        }

        app_id = Application.get_env(:jump_agent, :hubspot_app_id, "")

        case HubSpotAPI.get_account_info(temp_connection) do
          {:ok, account_info} ->
            connection_params = %{
              access_token: access_token,
              refresh_token: refresh_token,
              token_expires_at: DateTime.utc_now() |> DateTime.add(expires_in, :second) |> DateTime.truncate(:second),
              portal_id: to_string(account_info["portalId"] || ""),
              hub_domain: account_info["hubDomain"],
              app_id: app_id,
              scopes: scopes,
              connected_at: DateTime.utc_now() |> DateTime.truncate(:second)
            }

            case HubSpot.create_or_update_connection(user, connection_params) do
              {:ok, _connection} ->
                Logger.info("HubSpot connected successfully for user #{user.id}")

                conn
                |> delete_session(:hubspot_oauth_state)
                |> put_flash(:info, "HubSpot account connected successfully! Portal ID: #{connection_params.portal_id}")
                |> redirect(to: ~p"/dashboard")

              {:error, changeset} ->
                Logger.error("Failed to save HubSpot connection: #{inspect(changeset.errors)}")

                conn
                |> delete_session(:hubspot_oauth_state)
                |> put_flash(:error, "Failed to save HubSpot connection. Please try again.")
                |> redirect(to: ~p"/dashboard")
            end

          {:error, reason} ->
            Logger.error("Failed to get HubSpot account info: #{inspect(reason)}")

            app_id = Application.get_env(:jump_agent, :hubspot_app_id, "")

            # Still try to save the connection without account info
            connection_params = %{
              access_token: access_token,
              refresh_token: refresh_token,
              token_expires_at: DateTime.utc_now() |> DateTime.add(expires_in, :second) |> DateTime.truncate(:second),
              scopes: scopes,
              app_id: app_id,
              connected_at: DateTime.utc_now() |> DateTime.truncate(:second)
            }

            case HubSpot.create_or_update_connection(user, connection_params) do
              {:ok, _connection} ->
                conn
                |> delete_session(:hubspot_oauth_state)
                |> put_flash(:info, "HubSpot account connected successfully!")
                |> redirect(to: ~p"/dashboard")

              {:error, _} ->
                conn
                |> delete_session(:hubspot_oauth_state)
                |> put_flash(:error, "Failed to save HubSpot connection.")
                |> redirect(to: ~p"/dashboard")
            end
        end

      {:error, {:token_exchange_failed, _status, %{"message" => message}}} ->
        Logger.error("HubSpot token exchange failed: #{message}")

        conn
        |> delete_session(:hubspot_oauth_state)
        |> put_flash(:error, "Failed to connect HubSpot: #{message}")
        |> redirect(to: ~p"/dashboard")

      {:error, reason} ->
        Logger.error("HubSpot token exchange failed: #{inspect(reason)}")

        conn
        |> delete_session(:hubspot_oauth_state)
        |> put_flash(:error, "Failed to connect HubSpot account. Please try again.")
        |> redirect(to: ~p"/dashboard")
    end
  end
end
