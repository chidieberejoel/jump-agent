defmodule JumpAgent.Accounts.User do
  use JumpAgent.Schema

  schema "users" do
    field :email, :string
    field :name, :string
    field :google_id, :string
    field :avatar_url, :string
    field :google_access_token, :string, redact: true
    field :google_refresh_token, :string, redact: true
    field :google_token_expires_at, :utc_datetime
    field :last_login_at, :utc_datetime

    timestamps()
  end

  @doc false
  def google_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :google_id, :avatar_url])
    |> validate_required([:email, :google_id])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> unique_constraint(:email)
    |> unique_constraint(:google_id)
    |> put_change(:last_login_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc false
  def token_changeset(user, attrs) do
    user
    |> cast(attrs, [:google_access_token, :google_refresh_token, :google_token_expires_at])
    |> encrypt_tokens()
  end

  defp encrypt_tokens(changeset) do
    changeset
    |> encrypt_field(:google_access_token)
    |> encrypt_field(:google_refresh_token)
  end

  defp encrypt_field(changeset, field) do
    case get_change(changeset, field) do
      nil -> changeset
      value -> put_change(changeset, field, encrypt_token(value))
    end
  end

  @doc """
  Encrypts a token using application secret
  """
  def encrypt_token(token) when is_binary(token) do
    secret = Application.get_env(:jump_agent, :token_encryption_key) ||
      raise "Token encryption key not configured!"

    # Generate a random IV for each encryption
    iv = :crypto.strong_rand_bytes(16)

    encrypted = :crypto.crypto_one_time(:aes_256_ctr, secret, iv, token, true)

    # Prepend IV to encrypted data
    Base.encode64(iv <> encrypted)
  end

  @doc """
  Decrypts a token
  """
  def decrypt_token(nil), do: nil
  def decrypt_token(encrypted_token) when is_binary(encrypted_token) do
    secret = Application.get_env(:jump_agent, :token_encryption_key) ||
      raise "Token encryption key not configured!"

    # Decode and extract IV and encrypted data
    decoded = Base.decode64!(encrypted_token)
    <<iv::binary-size(16), encrypted::binary>> = decoded

    :crypto.crypto_one_time(:aes_256_ctr, secret, iv, encrypted, false)
  end

  @doc """
  Returns the decrypted access token
  """
  def decrypted_access_token(%__MODULE__{google_access_token: token}), do: decrypt_token(token)

  @doc """
  Returns the decrypted refresh token
  """
  def decrypted_refresh_token(%__MODULE__{google_refresh_token: token}), do: decrypt_token(token)
end
