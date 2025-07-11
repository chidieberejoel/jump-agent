defmodule JumpAgent.Repo.Migrations.AddWebhookFieldsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Gmail webhook fields
      add :gmail_watch_expiration, :utc_datetime
      add :gmail_history_id, :string

      # Calendar webhook fields
      add :calendar_watch_expiration, :utc_datetime
      add :calendar_channel_id, :string
      add :calendar_resource_id, :string
    end

    create index(:users, [:gmail_watch_expiration])
    create index(:users, [:calendar_watch_expiration])
  end
end
