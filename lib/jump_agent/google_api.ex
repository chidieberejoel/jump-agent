defmodule JumpAgent.GoogleAPI do
  @moduledoc """
  Helper module for making requests to Google APIs using stored user tokens.
  """

  @gmail_base_url "https://gmail.googleapis.com/gmail/v1"
  @calendar_base_url "https://www.googleapis.com/calendar/v3"
  @oauth_token_url "https://oauth2.googleapis.com/token"

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

  defp make_request(user, method, url, body, retry_count \\ 0) do
    # Check if token is expired and refresh if needed
    user =
      if Accounts.token_expired?(user) do
        Logger.info("Token expired for user #{user.id}, attempting refresh")

        case refresh_token(user) do
          {:ok, refreshed_user} -> refreshed_user
          {:error, reason} ->
            Logger.error("Token refresh failed: #{inspect(reason)}")
            user  # Continue with expired token, will likely get 401
        end
      else
        user
      end

    access_token = Accounts.get_access_token(user)

    if is_nil(access_token) do
      {:error, :no_access_token}
    else
      headers = [
        {"Authorization", "Bearer #{access_token}"},
        {"Content-Type", "application/json"},
        {"Accept", "application/json"}
      ]

      request_body = if body, do: Jason.encode!(body), else: ""

      case Finch.build(method, url, headers, request_body)
           |> Finch.request(JumpAgent.Finch, receive_timeout: 30_000) do
        {:ok, %Finch.Response{status: 200, body: response_body}} ->
          {:ok, Jason.decode!(response_body)}

        {:ok, %Finch.Response{status: status, body: response_body}} when status in 201..299 ->
          {:ok, Jason.decode!(response_body)}

        {:ok, %Finch.Response{status: 401, body: response_body}} when retry_count < 1 ->
          Logger.warning("Got 401, attempting token refresh for user #{user.id}")

          case refresh_token(user) do
            {:ok, refreshed_user} ->
              # Retry with refreshed token
              make_request(refreshed_user, method, url, body, retry_count + 1)

            {:error, reason} ->
              {:error, {:unauthorized, reason}}
          end

        {:ok, %Finch.Response{status: 401}} ->
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
      {:error, :no_refresh_token}
    else
      client_id = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)[:client_id]
      client_secret = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)[:client_secret]

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

      case Finch.build(:post, @oauth_token_url, headers, request_body)
           |> Finch.request(JumpAgent.Finch, receive_timeout: 10_000) do
        {:ok, %Finch.Response{status: 200, body: response_body}} ->
          response = Jason.decode!(response_body)

          expires_at =
            DateTime.utc_now()
            |> DateTime.add(response["expires_in"] || 3600, :second)
            |> DateTime.truncate(:second)

          case Accounts.update_user_tokens(
                 user,
                 response["access_token"],
                 response["refresh_token"] || refresh_token,  # Google doesn't always return a new refresh token
                 expires_at
               ) do
            {:ok, updated_user} ->
              Logger.info("Successfully refreshed token for user #{user.id}")
              {:ok, updated_user}

            {:error, changeset} ->
              Logger.error("Failed to save refreshed token: #{inspect(changeset.errors)}")
              {:error, changeset}
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
