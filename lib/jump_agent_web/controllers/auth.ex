defmodule JumpAgentWeb.AuthController do
  use JumpAgentWeb, :controller
  plug Ueberauth

  alias JumpAgent.Accounts
  require Logger

  def request(conn, _params) do
    # Handled by Ueberauth
    # The redirect_if_auth plug should prevent authenticated users from reaching here
  end

  def callback(%{assigns: %{ueberauth_failure: fails}} = conn, _params) do
    Logger.error("OAuth authentication failed: #{inspect(fails)}")

    error_message = case fails.errors do
      [%{message: message} | _] -> message
      _ -> "Authentication failed. Please try again."
    end

    conn
    |> put_flash(:error, error_message)
    |> redirect(to: ~p"/")
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    # Additional safety check - if user is already authenticated, redirect them
    if conn.assigns[:current_user] do
      Logger.warn("Authenticated user attempted to access OAuth callback")

      conn
      |> put_flash(:info, "You are already logged in.")
      |> redirect(to: ~p"/dashboard")
    else
      handle_oauth_callback(conn, auth)
    end
  end

  defp handle_oauth_callback(conn, auth) do
    Logger.info("OAuth callback received for provider: #{auth.provider}")

    user_params = %{
      email: auth.info.email,
      name: auth.info.name || auth.info.nickname,
      google_id: to_string(auth.uid),
      avatar_url: auth.info.image
    }

    case Accounts.create_or_update_user_from_google(user_params) do
      {:ok, user} ->
        # Store tokens if available
        token_result =
          if auth.credentials do
            # Ensure we have valid expiry time
            expires_at =
              if auth.credentials.expires_at do
                case DateTime.from_unix(auth.credentials.expires_at) do
                  {:ok, dt} -> DateTime.truncate(dt, :second)
                  {:error, _} ->
                    # Fallback if expires_at is not a valid unix timestamp
                    DateTime.utc_now()
                    |> DateTime.add(3600, :second)
                    |> DateTime.truncate(:second)
                end
              else
                # Default to 1 hour if no expiry provided
                DateTime.utc_now()
                |> DateTime.add(3600, :second)
                |> DateTime.truncate(:second)
              end

            # Make sure we have the tokens
            access_token = auth.credentials.token
            refresh_token = auth.credentials.refresh_token

            if access_token && refresh_token do
              case Accounts.update_user_tokens(
                 user,
                 access_token,
                 refresh_token,
                 expires_at
               ) do
                {:ok, updated_user} ->
                  # Set up webhooks after successful token update
                  setup_user_webhooks(updated_user)
                  {:ok, updated_user}

                error -> error
              end
            else
              Logger.warning("Missing tokens in OAuth response")
              {:ok, user}
            end
          else
            Logger.warning("No credentials in OAuth response")
            {:ok, user}
          end

        case token_result do
          {:ok, _user} ->
            Logger.info("User #{user.email} (#{user.id}) logged in successfully")

            conn
            |> put_session(:user_id, user.id)
            |> put_session(:live_socket_id, "users_sessions:#{user.id}")
            |> configure_session(renew: true)
            |> put_flash(:info, "Welcome back, #{user.name || user.email}!")
            |> redirect(to: ~p"/dashboard")

          {:error, changeset} ->
            Logger.error("Failed to update user tokens: #{inspect(changeset.errors)}")

            conn
            |> put_flash(:error, "Login successful but token storage failed. Some features may not work.")
            |> redirect(to: ~p"/dashboard")
        end

      {:error, changeset} ->
        Logger.error("Failed to create/update user: #{inspect(changeset.errors)}")

        conn
        |> put_flash(:error, "Authentication failed. Please try again.")
        |> redirect(to: ~p"/")
    end
  end

  def logout(conn, _params) do
    user_id = get_session(conn, :user_id)

    if user_id do
      Logger.info("User #{user_id} logged out")
    end

    user = Accounts.get_user!(user_id)
    cleanup_user_webhooks(user) # Cleanup webhooks when the user logs out

    conn
    |> configure_session(drop: true)
    |> put_flash(:info, "You have been logged out successfully.")
    |> redirect(to: ~p"/")
  end

  defp setup_user_webhooks(user) do
    # Set up Gmail webhook
    Task.start(fn ->
      case JumpAgent.WebhookService.setup_gmail_webhook(user) do
        {:ok, _} -> Logger.info("Gmail webhook setup successful for user #{user.id}")
        {:error, reason} -> Logger.warning("Gmail webhook setup failed for user #{user.id}: #{inspect(reason)}")
      end
    end)

    # Set up Calendar webhook
    Task.start(fn ->
      case JumpAgent.WebhookService.setup_calendar_webhook(user) do
        {:ok, _} -> Logger.info("Calendar webhook setup successful for user #{user.id}")
        {:error, reason} -> Logger.warning("Calendar webhook setup failed for user #{user.id}: #{inspect(reason)}")
      end
    end)
  end

  defp cleanup_user_webhooks(user) do
    Task.start(fn ->
      # Stop Gmail watch
      case JumpAgent.WebhookService.stop_gmail_webhook(user) do
        :ok -> Logger.info("Stopped Gmail webhook for #{user.email}")
        {:error, reason} -> Logger.warning("Failed to stop Gmail webhook: #{inspect(reason)}")
      end

      # Stop Calendar watch
      if user.calendar_channel_id && user.calendar_resource_id do
        case JumpAgent.WebhookService.stop_calendar_webhook(user) do
          :ok -> Logger.info("Stopped Calendar webhook for #{user.email}")
          {:error, reason} -> Logger.warning("Failed to stop Calendar webhook: #{inspect(reason)}")
        end
      end

      # TODO; Also stop hubspot webhooks

      # Clear webhook data from database
      Accounts.update_user_webhook_info(user, %{
        gmail_watch_expiration: nil,
        gmail_history_id: nil,
        calendar_watch_expiration: nil,
        calendar_channel_id: nil,
        calendar_resource_id: nil
      })
    end)
  end
end
