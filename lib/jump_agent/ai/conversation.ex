defmodule JumpAgent.AI.Conversation do
  use JumpAgent.Schema
  alias JumpAgent.Accounts.User
  alias JumpAgent.AI.Message

  schema "ai_conversations" do
    field :title, :string
    field :context, :map, default: %{}
    field :is_active, :boolean, default: true
    field :last_message_at, :utc_datetime

    belongs_to :user, User
    has_many :messages, Message

    timestamps()
  end

  @doc false
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:user_id, :title, :context, :is_active, :last_message_at])
    |> validate_required([:user_id])
    |> foreign_key_constraint(:user_id)
  end
end
