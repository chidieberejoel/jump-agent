defmodule JumpAgent.AI.Message do
  use JumpAgent.Schema
  alias JumpAgent.Accounts.User
  alias JumpAgent.AI.Conversation

  schema "ai_messages" do
    field :role, :string # "user", "assistant", "system"
    field :content, :string
    field :metadata, :map, default: %{}
    field :tool_calls, {:array, :map}, default: []
    field :tool_call_id, :string

    belongs_to :conversation, Conversation
    belongs_to :user, User

    timestamps()
  end

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:conversation_id, :user_id, :role, :content, :metadata, :tool_calls, :tool_call_id])
    |> validate_required([:conversation_id, :user_id, :role, :content])
    |> validate_inclusion(:role, ["user", "assistant", "system", "tool"])
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:user_id)
  end
end
