defmodule JumpAgent.AI.Instruction do
  use JumpAgent.Schema
  alias JumpAgent.Accounts.User

  @valid_instruction_types ["ongoing", "temporary"]
  @valid_trigger_types ["email_received", "calendar_event_created", "hubspot_contact_created",
    "hubspot_contact_updated", "manual", "scheduled"]

  schema "ai_instructions" do
    field :instruction_type, :string
    field :trigger_type, :string
    field :instruction, :string
    field :conditions, :map, default: %{}
    field :actions, {:array, :map}, default: []
    field :is_active, :boolean, default: true
    field :expires_at, :utc_datetime

    belongs_to :user, User

    timestamps()
  end

  @doc false
  def changeset(instruction, attrs) do
    instruction
    |> cast(attrs, [:user_id, :instruction_type, :trigger_type, :instruction,
      :conditions, :actions, :is_active, :expires_at])
    |> validate_required([:user_id, :instruction_type, :instruction])
    |> validate_inclusion(:instruction_type, @valid_instruction_types)
    |> validate_inclusion(:trigger_type, @valid_trigger_types)
    |> foreign_key_constraint(:user_id)
  end

  def valid_instruction_types, do: @valid_instruction_types
  def valid_trigger_types, do: @valid_trigger_types
end
