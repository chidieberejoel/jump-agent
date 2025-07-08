defmodule JumpAgent.HubSpot do
  @moduledoc """
  The HubSpot context.
  """

  import Ecto.Query, warn: false
  alias JumpAgent.Repo
  alias JumpAgent.HubSpot.Connection
  alias JumpAgent.Accounts.User
  require Logger

  @doc """
  Gets a HubSpot connection by user.
  """
  def get_connection_by_user(%User{} = user) do
    Repo.get_by(Connection, user_id: user.id)
  end

  @doc """
  Creates or updates a HubSpot connection from OAuth data.
  """
  def create_or_update_connection(user, attrs) do
    case get_connection_by_user(user) do
      nil ->
        Logger.info("Creating new HubSpot connection for user #{user.id}")

        %Connection{}
        |> Connection.changeset(Map.put(attrs, :user_id, user.id))
        |> Repo.insert()

      connection ->
        Logger.info("Updating existing HubSpot connection for user #{user.id}")

        connection
        |> Connection.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Updates the connection's tokens.
  """
  def update_connection_tokens(connection, access_token, refresh_token, expires_in) do
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(expires_in, :second)
      |> DateTime.truncate(:second)

    connection
    |> Connection.token_changeset(%{
      access_token: access_token,
      refresh_token: refresh_token,
      token_expires_at: expires_at
    })
    |> Repo.update()
  end

  @doc """
  Check if connection's token is expired
  """
  def token_expired?(%Connection{token_expires_at: nil}), do: true
  def token_expired?(%Connection{token_expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :lt
  end

  @doc """
  Get decrypted access token
  """
  def get_access_token(%Connection{} = connection) do
    Connection.decrypted_access_token(connection)
  end

  @doc """
  Get decrypted refresh token
  """
  def get_refresh_token(%Connection{} = connection) do
    Connection.decrypted_refresh_token(connection)
  end

  @doc """
  Delete a HubSpot connection
  """
  def delete_connection(%Connection{} = connection) do
    Repo.delete(connection)
  end

  @doc """
  Lists all active HubSpot connections.
  """
  def list_all_connections do
    Connection
    |> Repo.all()
    |> Repo.preload(:user)
  end

  @doc """
  Gets the user for a connection.
  """
  def get_connection_user(%Connection{} = connection) do
    connection = Repo.preload(connection, :user)
    connection.user
  end

  @doc """
  Gets a connection by portal ID.
  """
  def get_connection_by_portal_id(portal_id) when is_binary(portal_id) do
    Repo.get_by(Connection, portal_id: portal_id)
  end
end
