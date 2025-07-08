defmodule JumpAgent.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :name, :string
      add :google_id, :string, null: false
      add :avatar_url, :string
      add :google_access_token, :text
      add :google_refresh_token, :text
      add :google_token_expires_at, :utc_datetime
      add :last_login_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:google_id])
    create index(:users, [:last_login_at])
  end
end
