defmodule JumpAgent.HubSpotAPI do
  @moduledoc """
  Helper module for making requests to HubSpot APIs using stored connection tokens.
  """

  @base_url "https://api.hubapi.com"
  @oauth_base_url "https://api.hubspot.com/oauth/v1"
  @max_retries 2
  @timeout 30_000

  alias JumpAgent.HubSpot
  alias JumpAgent.HubSpot.Connection
  require Logger

  @doc """
  Get account info to verify connection
  """
  def get_account_info(connection) do
    make_request(connection, :get, "/account-info/v3/details")
  end

  @doc """
  Get owners (HubSpot users) with caching support
  """
  def list_owners(connection, opts \\ []) do
    query = URI.encode_query(opts)
    make_request(connection, :get, "/crm/v3/owners?#{query}")
  end

  @doc """
  List contacts with pagination and property selection
  """
  def list_contacts(connection, opts \\ []) do
    default_opts = [
      limit: 100,
      properties: "firstname,lastname,email,company,lifecyclestage,createdate,lastmodifieddate"
    ]
    params = Keyword.merge(default_opts, opts)
    query = URI.encode_query(params)
    make_request(connection, :get, "/crm/v3/objects/contacts?#{query}")
  end

  @doc """
  Get a specific contact with all properties
  """
  def get_contact(connection, contact_id, properties \\ nil) do
    path = "/crm/v3/objects/contacts/#{contact_id}"
    path = if properties, do: "#{path}?properties=#{properties}", else: path
    make_request(connection, :get, path)
  end

  @doc """
  Create a contact with validation
  """
  def create_contact(connection, properties) do
    # Validate required fields
    if !Map.has_key?(properties, "email") || properties["email"] == "" do
      {:error, {:validation_error, "Email is required"}}
    else
      body = %{properties: properties}
      make_request(connection, :post, "/crm/v3/objects/contacts", body)
    end
  end

  @doc """
  Update a contact
  """
  def update_contact(connection, contact_id, properties) do
    body = %{properties: properties}
    make_request(connection, :patch, "/crm/v3/objects/contacts/#{contact_id}", body)
  end

  @doc """
  Delete a contact
  """
  def delete_contact(connection, contact_id) do
    make_request(connection, :delete, "/crm/v3/objects/contacts/#{contact_id}")
  end

  @doc """
  Search contacts with advanced filtering
  """
  def search_contacts(connection, filters, properties \\ [], limit \\ 100, after_id \\ nil) do
    body = %{
      filterGroups: [%{filters: filters}],
      properties: properties,
      limit: limit
    }

    body = if after_id, do: Map.put(body, :after, after_id), else: body

    make_request(connection, :post, "/crm/v3/objects/contacts/search", body)
  end

  @doc """
  Batch create contacts
  """
  def batch_create_contacts(connection, contacts) when is_list(contacts) do
    inputs = Enum.map(contacts, fn properties ->
      %{properties: properties}
    end)

    body = %{inputs: inputs}
    make_request(connection, :post, "/crm/v3/objects/contacts/batch/create", body)
  end

  @doc """
  Get timeline events for an object
  """
  def get_timeline_events(connection, object_type, object_id, opts \\ []) do
    query = URI.encode_query(opts)
    make_request(connection, :get, "/crm/v3/timeline/events?objectType=#{object_type}&objectId=#{object_id}&#{query}")
  end

  @doc """
  Create a timeline event
  """
  def create_timeline_event(connection, event_data) do
    make_request(connection, :post, "/crm/v3/timeline/events", event_data)
  end

  @doc """
  Get sales emails (engagements) with better filtering
  """
  def list_sales_emails(connection, opts \\ []) do
    params = Keyword.merge([limit: 100, type: "EMAIL"], opts)
    query = URI.encode_query(params)
    make_request(connection, :get, "/engagements/v1/engagements/paged?#{query}")
  end

  @doc """
  Get email engagement by ID
  """
  def get_email_engagement(connection, engagement_id) do
    make_request(connection, :get, "/engagements/v1/engagements/#{engagement_id}")
  end

  @doc """
  Create an engagement (email, note, task, etc.)
  """
  def create_engagement(connection, engagement_data) do
    make_request(connection, :post, "/engagements/v1/engagements", engagement_data)
  end

  @doc """
  Exchange authorization code for tokens
  """
  def exchange_code_for_token(code, redirect_uri) do
    client_id = Application.get_env(:jump_agent, :hubspot_client_id) ||
      raise "HubSpot client ID not configured"
    client_secret = Application.get_env(:jump_agent, :hubspot_client_secret) ||
      raise "HubSpot client secret not configured"

    body = %{
      grant_type: "authorization_code",
      client_id: client_id,
      client_secret: client_secret,
      redirect_uri: redirect_uri,
      code: code
    }

    headers = [
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Accept", "application/json"}
    ]

    request_body = URI.encode_query(body)

    case Finch.build(:post, "#{@oauth_base_url}/token", headers, request_body)
         |> Finch.request(JumpAgent.Finch, receive_timeout: 10_000) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        {:ok, Jason.decode!(response_body)}

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        Logger.error("HubSpot token exchange failed with status #{status}: #{response_body}")

        error = try do
          Jason.decode!(response_body)
        rescue
          _ -> %{"message" => "Token exchange failed", "details" => response_body}
        end

        {:error, {:token_exchange_failed, status, error}}

      {:error, reason} ->
        Logger.error("HubSpot token exchange request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Refresh the access token using the refresh token.
  """
  def refresh_token(%Connection{} = connection) do
    refresh_token = HubSpot.get_refresh_token(connection)

    if is_nil(refresh_token) do
      {:error, :no_refresh_token}
    else
      client_id = Application.get_env(:jump_agent, :hubspot_client_id)
      client_secret = Application.get_env(:jump_agent, :hubspot_client_secret)

      body = %{
        grant_type: "refresh_token",
        client_id: client_id,
        client_secret: client_secret,
        refresh_token: refresh_token
      }

      headers = [
        {"Content-Type", "application/x-www-form-urlencoded"},
        {"Accept", "application/json"}
      ]

      request_body = URI.encode_query(body)

      case Finch.build(:post, "#{@oauth_base_url}/token", headers, request_body)
           |> Finch.request(JumpAgent.Finch, receive_timeout: 10_000) do
        {:ok, %Finch.Response{status: 200, body: response_body}} ->
          response = Jason.decode!(response_body)

          case HubSpot.update_connection_tokens(
                 connection,
                 response["access_token"],
                 response["refresh_token"],
                 response["expires_in"] || 21600  # Default to 6 hours
               ) do
            {:ok, updated_connection} ->
              Logger.info("Successfully refreshed HubSpot token for connection #{connection.id}")
              {:ok, updated_connection}

            {:error, changeset} ->
              Logger.error("Failed to save refreshed HubSpot token: #{inspect(changeset.errors)}")
              {:error, changeset}
          end

        {:ok, %Finch.Response{status: status, body: response_body}} ->
          Logger.error("HubSpot token refresh failed with status #{status}: #{response_body}")

          error = try do
            Jason.decode!(response_body)
          rescue
            _ -> %{"message" => "Token refresh failed", "details" => response_body}
          end

          {:error, {:refresh_failed, status, error}}

        {:error, reason} ->
          Logger.error("HubSpot token refresh request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Revoke access token (for disconnect)
  """
  def revoke_token(access_token) do
    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Accept", "application/json"}
    ]

    # Note: Token revocation uses api.hubapi.com, not api.hubspot.com
    case Finch.build(:delete, "#{@base_url}/oauth/v1/access-tokens/#{access_token}", headers, "")
         |> Finch.request(JumpAgent.Finch, receive_timeout: 10_000) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 ->
        :ok

      _ ->
        # Even if revocation fails, we'll still delete the local connection
        Logger.warning("Failed to revoke HubSpot token, but will proceed with disconnect")
        :ok
    end
  end

  # Private functions

  defp make_request(connection, method, path, body \\ nil, retry_count \\ 0) do
    # Check if token is expired and refresh if needed
    connection =
      if HubSpot.token_expired?(connection) do
        Logger.info("HubSpot token expired for connection #{connection.id}, attempting refresh")

        case refresh_token(connection) do
          {:ok, refreshed_connection} -> refreshed_connection
          {:error, reason} ->
            Logger.error("HubSpot token refresh failed: #{inspect(reason)}")
            connection  # Continue with expired token, will likely get 401
        end
      else
        connection
      end

    access_token = HubSpot.get_access_token(connection)

    if is_nil(access_token) do
      {:error, :no_access_token}
    else
      headers = [
        {"Authorization", "Bearer #{access_token}"},
        {"Content-Type", "application/json"},
        {"Accept", "application/json"}
      ]

      url = @base_url <> path
      request_body = if body, do: Jason.encode!(body), else: ""

      Logger.debug("HubSpot API request: #{method} #{url}")

      case Finch.build(method, url, headers, request_body)
           |> Finch.request(JumpAgent.Finch, receive_timeout: @timeout) do
        {:ok, %Finch.Response{status: status, body: response_body}} when status in 200..299 ->
          decode_response(response_body)

        {:ok, %Finch.Response{status: 204}} ->
          # No content response (success)
          {:ok, %{}}

        {:ok, %Finch.Response{status: 401}} when retry_count < @max_retries ->
          Logger.warning("Got 401, attempting HubSpot token refresh for connection #{connection.id}")

          case refresh_token(connection) do
            {:ok, refreshed_connection} ->
              # Retry with refreshed token
              make_request(refreshed_connection, method, path, body, retry_count + 1)

            {:error, reason} ->
              {:error, {:unauthorized, reason}}
          end

        {:ok, %Finch.Response{status: 401}} ->
          {:error, :unauthorized}

        {:ok, %Finch.Response{status: 404}} ->
          {:error, :not_found}

        {:ok, %Finch.Response{status: 429, headers: headers}} ->
          retry_after = get_retry_after(headers)
          {:error, {:rate_limited, retry_after}}

        {:ok, %Finch.Response{status: status, body: response_body}} ->
          Logger.error("HubSpot API error: #{status} - #{response_body}")

          error = try do
            Jason.decode!(response_body)
          rescue
            _ -> %{"message" => response_body}
          end

          {:error, {status, error}}

        {:error, %Mint.TransportError{reason: :timeout}} ->
          Logger.error("HubSpot API request timeout")
          {:error, :timeout}

        {:error, reason} ->
          Logger.error("HubSpot request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp decode_response(""), do: {:ok, %{}}
  defp decode_response(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} ->
        Logger.error("Failed to decode HubSpot response: #{inspect(reason)}")
        {:error, {:decode_error, reason}}
    end
  end

  defp get_retry_after(headers) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, value} ->
        case Integer.parse(value) do
          {seconds, _} -> seconds
          _ -> 60
        end
      nil -> 60  # Default to 60 seconds
    end
  end
end
