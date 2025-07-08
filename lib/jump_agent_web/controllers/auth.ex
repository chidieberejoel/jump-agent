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
              Accounts.update_user_tokens(
                user,
                access_token,
                refresh_token,
                expires_at
              )
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
            |> put_flash(:error, "Authentication succeeded but failed to save credentials.")
            |> redirect(to: ~p"/")
        end

      {:error, changeset} ->
        Logger.error("Failed to create/update user: #{inspect(changeset.errors)}")

        conn
        |> put_flash(:error, "Failed to create or update user account.")
        |> redirect(to: ~p"/")
    end
  rescue
    error ->
      Logger.error("Unexpected error in OAuth callback: #{inspect(error)}")

      conn
      |> put_flash(:error, "An unexpected error occurred. Please try again.")
      |> redirect(to: ~p"/")
  end

  def logout(conn, _params) do
    user_id = get_session(conn, :user_id)

    if user_id do
      Logger.info("User #{user_id} logged out")
    end

    conn
    |> configure_session(drop: true)
    |> put_flash(:info, "You have been logged out successfully.")
    |> redirect(to: ~p"/")
  end
end
