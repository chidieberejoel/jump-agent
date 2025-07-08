defmodule JumpAgent.HubSpot.Connection do
  use JumpAgent.Schema
  alias JumpAgent.Accounts.User

  schema "hubspot_connections" do
    field :portal_id, :string
    field :access_token, :string, redact: true
    field :refresh_token, :string, redact: true
    field :token_expires_at, :utc_datetime
    field :scopes, {:array, :string}
    field :hub_domain, :string
    field :app_id, :string
    field :connected_at, :utc_datetime

    belongs_to :user, User

    timestamps()
  end

  @doc false
  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [:user_id, :portal_id, :access_token, :refresh_token,
      :token_expires_at, :scopes, :hub_domain, :app_id, :connected_at])
    |> validate_required([:user_id, :access_token])
    |> unique_constraint(:user_id)
    |> encrypt_tokens()
  end

  @doc false
  def token_changeset(connection, attrs) do
    connection
    |> cast(attrs, [:access_token, :refresh_token, :token_expires_at])
    |> encrypt_tokens()
  end

  defp encrypt_tokens(changeset) do
    changeset
    |> encrypt_field(:access_token)
    |> encrypt_field(:refresh_token)
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
    secret = get_encryption_key()

    iv = :crypto.strong_rand_bytes(16)
    encrypted = :crypto.crypto_one_time(:aes_256_ctr, secret, iv, token, true)
    Base.encode64(iv <> encrypted)
  end

  @doc """
  Decrypts a token
  """
  def decrypt_token(nil), do: nil
  def decrypt_token(encrypted_token) when is_binary(encrypted_token) do
    secret = get_encryption_key()

    decoded = Base.decode64!(encrypted_token)
    <<iv::binary-size(16), encrypted::binary>> = decoded
    :crypto.crypto_one_time(:aes_256_ctr, secret, iv, encrypted, false)
  end

  defp get_encryption_key do
    case Application.get_env(:jump_agent, :token_encryption_key) do
      nil ->
        raise "Token encryption key not configured!"
      key when is_binary(key) and byte_size(key) == 32 ->
        key
      key when is_binary(key) ->
        raise "Invalid encryption key size: expected 32 bytes, got #{byte_size(key)} bytes"
      key ->
        raise "Invalid encryption key type: #{inspect(key)}"
    end
  end

  @doc """
  Returns the decrypted access token
  """
  def decrypted_access_token(%__MODULE__{access_token: token}), do: decrypt_token(token)

  @doc """
  Returns the decrypted refresh token
  """
  def decrypted_refresh_token(%__MODULE__{refresh_token: token}), do: decrypt_token(token)
end
