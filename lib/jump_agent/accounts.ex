# Fix 1: Update lib/jump_agent/accounts.ex to remove duplicate function and fix token handling
defmodule JumpAgent.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias JumpAgent.Repo

  alias JumpAgent.Accounts.User
  require Logger

  @doc """
  Gets a single user by UUID.

  ## Examples

      iex> get_user!("550e8400-e29b-41d4-a716-446655440000")
      %User{}

      iex> get_user!("invalid-uuid")
      ** (Ecto.NoResultsError)
  """
  def get_user!(id) when is_binary(id), do: Repo.get!(User, id)

  @doc """
  Gets a single user by UUID, returns nil if not found.

  ## Examples

      iex> get_user("550e8400-e29b-41d4-a716-446655440000")
      %User{}

      iex> get_user("550e8400-e29b-41d4-a716-446655440001")
      nil
  """
  def get_user(id) when is_binary(id), do: Repo.get(User, id)

  @doc """
  Gets a user by email.
  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Creates or updates a user from Google OAuth data.
  """
  def create_or_update_user_from_google(attrs) do
    case get_user_by_email(attrs.email) do
      nil ->
        Logger.info("Creating new user with email: #{attrs.email}")

        %User{}
        |> User.google_changeset(attrs)
        |> Repo.insert()

      user ->
        Logger.info("Updating existing user with email: #{attrs.email}")

        user
        |> User.google_changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Updates the user's Google OAuth tokens.
  """
  def update_user_tokens(user, access_token, refresh_token, expires_at) do
    # Ensure we have valid tokens
    attrs = %{}

    attrs = if access_token && access_token != "",
               do: Map.put(attrs, :google_access_token, access_token),
               else: attrs

    attrs = if refresh_token && refresh_token != "",
               do: Map.put(attrs, :google_refresh_token, refresh_token),
               else: attrs

    attrs = Map.put(attrs, :google_token_expires_at, expires_at)

    user
    |> User.token_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Check if user's token is expired
  """
  def token_expired?(%User{google_token_expires_at: nil}), do: true
  def token_expired?(%User{google_token_expires_at: expires_at}) do
    # Add a 5-minute buffer to handle clock skew
    buffer_time = DateTime.add(DateTime.utc_now(), 300, :second)
    DateTime.compare(expires_at, buffer_time) == :lt
  end

  @doc """
  Get decrypted access token
  """
  def get_access_token(%User{} = user) do
    User.decrypted_access_token(user)
  end

  @doc """
  Get decrypted refresh token
  """
  def get_refresh_token(%User{} = user) do
    User.decrypted_refresh_token(user)
  end

  @doc """
  Lists all users with valid Google tokens.
  """
  def list_users_with_google_tokens do
    User
    |> where([u], not is_nil(u.google_access_token))
    |> where([u], not is_nil(u.google_refresh_token))
    |> Repo.all()
  end

  @doc """
  Lists all users.
  """
  def list_all_users do
    Repo.all(User)
  end

  @doc """
  Clears expired tokens for a user (for security)
  """
  def clear_expired_tokens(%User{} = user) do
    if token_expired?(user) do
      user
      |> User.token_changeset(%{
        google_access_token: nil,
        google_token_expires_at: nil
      })
      |> Repo.update()
    else
      {:ok, user}
    end
  end
end

