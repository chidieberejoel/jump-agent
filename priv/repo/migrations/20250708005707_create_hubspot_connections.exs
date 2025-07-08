defmodule JumpAgent.Repo.Migrations.CreateHubspotConnections do
  use Ecto.Migration

  def change do
    create table(:hubspot_connections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :portal_id, :string
      add :access_token, :text
      add :refresh_token, :text
      add :token_expires_at, :utc_datetime
      add :scopes, {:array, :string}
      add :hub_domain, :string
      add :app_id, :string
      add :connected_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:hubspot_connections, [:user_id])
    create index(:hubspot_connections, [:portal_id])
  end
end
