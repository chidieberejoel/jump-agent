defmodule JumpAgent.GoogleAPI do
  @moduledoc """
  Helper module for making requests to Google APIs using stored user tokens.
  """

  @gmail_base_url "https://gmail.googleapis.com/gmail/v1"
  @calendar_base_url "https://www.googleapis.com/calendar/v3"
  @oauth_token_url "https://oauth2.googleapis.com/token"
  @max_retries 2

  alias JumpAgent.Accounts
  alias JumpAgent.Accounts.User
  require Logger

  @doc """
  Makes a request to Gmail API.
  """
  def gmail_request(user, method, path, body \\ nil) do
    url = @gmail_base_url <> path
    make_request(user, method, url, body)
  end

  @doc """
  Makes a request to Calendar API.
  """
  def calendar_request(user, method, path, body \\ nil) do
    url = @calendar_base_url <> path
    make_request(user, method, url, body)
  end

  @doc """
  Get user's Gmail profile.
  """
  def get_gmail_profile(user) do
    gmail_request(user, :get, "/users/me/profile")
  end

  @doc """
  List user's calendars.
  """
  def list_calendars(user) do
    calendar_request(user, :get, "/users/me/calendarList")
  end

  @doc """
  Get user's primary calendar events.
  """
  def list_calendar_events(user, calendar_id \\ "primary", opts \\ []) do
    query = URI.encode_query(opts)
    calendar_request(user, :get, "/calendars/#{calendar_id}/events?#{query}")
  end

  @doc """
  List recent emails
  """
  def list_emails(user, opts \\ []) do
    default_opts = [maxResults: 10]
    query = URI.encode_query(Keyword.merge(default_opts, opts))
    gmail_request(user, :get, "/users/me/messages?#{query}")
  end

  @doc """
  Get email details
  """
  def get_email(user, message_id) do
    gmail_request(user, :get, "/users/me/messages/#{message_id}")
  end

  @doc """
  Send an email
  """
  def send_email(user, message) do
    # Build the raw email
    raw_message = build_raw_email(message)

    # Base64 encode it for the API
    encoded = Base.url_encode64(raw_message, padding: false)

    body = %{raw: encoded}

    gmail_request(user, :post, "/users/me/messages/send", body)
  end

  @doc """
  Create a calendar event
  """
  def create_calendar_event(user, event, calendar_id \\ "primary") do
    calendar_request(user, :post, "/calendars/#{calendar_id}/events", event)
  end

  defp build_raw_email(message) do
    to = message.to
    subject = message.subject
    body = message.body
    cc = if message[:cc], do: "Cc: #{Enum.join(message.cc, ", ")}\r\n", else: ""
    bcc = if message[:bcc], do: "Bcc: #{Enum.join(message.bcc, ", ")}\r\n", else: ""

    """
    To: #{to}\r
    Subject: #{subject}\r
    #{cc}#{bcc}Content-Type: text/plain; charset=UTF-8\r
    \r
    #{body}
    """
  end

  defp make_request(user, method, url, body, retry_count \\ 0) do
    # Reload user to get fresh token data
    user = Accounts.get_user!(user.id)

    # Check if token is expired and refresh if needed
    user =
      if Accounts.token_expired?(user) do
        Logger.info("Token expired for user #{user.id} (#{user.email}), attempting refresh")

        case refresh_token(user) do
          {:ok, refreshed_user} ->
            refreshed_user
          {:error, reason} ->
            Logger.error("Token refresh failed: #{inspect(reason)}")
            user  # Continue with expired token, will likely get 401
        end
      else
        user
      end

    access_token = Accounts.get_access_token(user)

    if is_nil(access_token) do
      Logger.error("No access token available for user #{user.id}")
      {:error, :no_access_token}
    else
      headers = [
        {"Authorization", "Bearer #{access_token}"},
        {"Content-Type", "application/json"},
        {"Accept", "application/json"}
      ]

      request_body = if body, do: Jason.encode!(body), else: ""

      Logger.debug("Making #{method} request to #{url}")

      case Finch.build(method, url, headers, request_body)
           |> Finch.request(JumpAgent.Finch, receive_timeout: 30_000) do
        {:ok, %Finch.Response{status: status, body: response_body}} when status in 200..299 ->
          if response_body == "" do
            {:ok, %{}}
          else
            {:ok, Jason.decode!(response_body)}
          end

        {:ok, %Finch.Response{status: 401, body: response_body}} when retry_count < @max_retries ->
          Logger.warning("Got 401, attempting token refresh for user #{user.id} (#{user.email})")

          case refresh_token(user) do
            {:ok, refreshed_user} ->
              # Retry with refreshed token
              make_request(refreshed_user, method, url, body, retry_count + 1)

            {:error, reason} ->
              Logger.error("Token refresh failed: #{inspect(reason)}")
              {:error, {:unauthorized, reason}}
          end

        {:ok, %Finch.Response{status: 401, body: response_body}} ->
          Logger.error("Authentication failed after #{retry_count} retries: #{response_body}")
          {:error, :unauthorized}

        {:ok, %Finch.Response{status: 429, headers: headers}} ->
          retry_after = get_retry_after(headers)
          {:error, {:rate_limited, retry_after}}

        {:ok, %Finch.Response{status: status, body: response_body}} ->
          Logger.error("Google API error: #{status} - #{response_body}")

          error = try do
            Jason.decode!(response_body)
          rescue
            _ -> %{"error" => response_body}
          end

          {:error, {status, error}}

        {:error, reason} ->
          Logger.error("Request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp get_retry_after(headers) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, value} -> String.to_integer(value)
      nil -> 60  # Default to 60 seconds
    end
  end

  @doc """
  Refresh the user's access token using the refresh token.
  """
  def refresh_token(%User{} = user) do
    refresh_token = Accounts.get_refresh_token(user)

    if is_nil(refresh_token) do
      Logger.error("No refresh token available for user #{user.id}")
      {:error, :no_refresh_token}
    else
      client_id = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)[:client_id]
      client_secret = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)[:client_secret]

      if is_nil(client_id) || is_nil(client_secret) do
        Logger.error("Google OAuth client credentials not configured")
        {:error, :oauth_not_configured}
      else
        body = %{
          grant_type: "refresh_token",
          refresh_token: refresh_token,
          client_id: client_id,
          client_secret: client_secret
        }

        headers = [
          {"Content-Type", "application/x-www-form-urlencoded"},
          {"Accept", "application/json"}
        ]

        request_body = URI.encode_query(body)

        Logger.info("Attempting to refresh token for user #{user.id}")

        case Finch.build(:post, @oauth_token_url, headers, request_body)
             |> Finch.request(JumpAgent.Finch, receive_timeout: 10_000) do
          {:ok, %Finch.Response{status: 200, body: response_body}} ->
            response = Jason.decode!(response_body)

            access_token = response["access_token"]
            # Google may not always return a new refresh token
            new_refresh_token = response["refresh_token"] || refresh_token
            expires_in = response["expires_in"] || 3600

            expires_at =
              DateTime.utc_now()
              |> DateTime.add(expires_in, :second)
              |> DateTime.truncate(:second)

            case Accounts.update_user_tokens(
                   user,
                   access_token,
                   new_refresh_token,
                   expires_at
                 ) do
              {:ok, updated_user} ->
                Logger.info("Successfully refreshed token for user #{user.id} (#{user.email})")
                {:ok, updated_user}

              {:error, changeset} ->
                Logger.error("Failed to save refreshed token: #{inspect(changeset.errors)}")
                {:error, changeset}
            end

          {:ok, %Finch.Response{status: 400, body: response_body}} ->
            error = Jason.decode!(response_body)
            Logger.error("Token refresh failed with 400: #{inspect(error)}")

            # Check for specific error types
            if error["error"] == "invalid_grant" do
              # The refresh token is invalid, user needs to re-authenticate
              {:error, :invalid_refresh_token}
            else
              {:error, {:refresh_failed, 400, error}}
            end

          {:ok, %Finch.Response{status: status, body: response_body}} ->
            Logger.error("Token refresh failed with status #{status}: #{response_body}")
            {:error, {:refresh_failed, status, response_body}}

          {:error, reason} ->
            Logger.error("Token refresh request failed: #{inspect(reason)}")
            {:error, reason}
        end
      end
    end
  end
end
