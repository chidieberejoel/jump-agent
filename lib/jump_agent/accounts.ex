defmodule JumpAgent.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias JumpAgent.Repo

  alias JumpAgent.Accounts.User
  require Logger

#  @doc """
#  Returns the list of users.
#
#  ## Examples
#
#      iex> list_users()
#      [%User{}, ...]
#
#  """
#  def list_users do
#    Repo.all(User)
#  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Gets a single user, returns nil if not found.
  """
  def get_user(id), do: Repo.get(User, id)

  @doc """
  Gets a user by email.
  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end
#
#  @doc """
#  Creates a user.
#
#  ## Examples
#
#      iex> create_user(%{field: value})
#      {:ok, %User{}}
#
#      iex> create_user(%{field: bad_value})
#      {:error, %Ecto.Changeset{}}
#
#  """
#  def create_user(attrs \\ %{}) do
#    %User{}
#    |> User.changeset(attrs)
#    |> Repo.insert()
#  end
#
#  @doc """
#  Updates a user.
#
#  ## Examples
#
#      iex> update_user(user, %{field: new_value})
#      {:ok, %User{}}
#
#      iex> update_user(user, %{field: bad_value})
#      {:error, %Ecto.Changeset{}}
#
#  """
#  def update_user(%User{} = user, attrs) do
#    user
#    |> User.changeset(attrs)
#    |> Repo.update()
#  end

#  @doc """
#  Deletes a user.
#
#  ## Examples
#
#      iex> delete_user(user)
#      {:ok, %User{}}
#
#      iex> delete_user(user)
#      {:error, %Ecto.Changeset{}}
#
#  """
#  def delete_user(%User{} = user) do
#    Repo.delete(user)
#  end

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
  Updates the user's refresh token.
  """
  def update_user_tokens(user, access_token, refresh_token, expires_at) do
    user
    |> User.token_changeset(%{
      google_access_token: access_token,
      google_refresh_token: refresh_token,
      google_token_expires_at: expires_at
    })
    |> Repo.update()
  end

  @doc """
  Check if user's token is expired
  """
  def token_expired?(%User{google_token_expires_at: nil}), do: false
  def token_expired?(%User{google_token_expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :lt
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

#  @doc """
#  Returns an `%Ecto.Changeset{}` for tracking user changes.
#
#  ## Examples
#
#      iex> change_user(user)
#      %Ecto.Changeset{data: %User{}}
#
#  """
#  def change_user(%User{} = user, attrs \\ %{}) do
#    User.changeset(user, attrs)
#  end
end
