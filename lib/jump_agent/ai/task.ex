defmodule JumpAgent.AI.Task do
  use JumpAgent.Schema
  alias JumpAgent.Accounts.User
  alias JumpAgent.AI.{Conversation, Message}

  @valid_statuses ["pending", "in_progress", "waiting", "completed", "failed"]
  @valid_types ["schedule_meeting", "send_email", "create_contact", "update_contact",
    "create_calendar_event", "search_information", "add_hubspot_note"]

  schema "ai_tasks" do
    field :type, :string
    field :status, :string, default: "pending"
    field :parameters, :map, default: %{}
    field :context, :map, default: %{}
    field :result, :map
    field :error, :string
    field :attempts, :integer, default: 0
    field :scheduled_at, :utc_datetime
    field :completed_at, :utc_datetime

    belongs_to :user, User
    belongs_to :conversation, Conversation
    belongs_to :message, Message

    timestamps()
  end

  @doc false
  def changeset(task, attrs) do
    task
    |> cast(attrs, [:user_id, :conversation_id, :message_id, :type, :status,
      :parameters, :context, :result, :error, :attempts,
      :scheduled_at, :completed_at])
    |> validate_required([:user_id, :type, :status])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:type, @valid_types)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:message_id)
  end

  def valid_types, do: @valid_types
  def valid_statuses, do: @valid_statuses
end
