defmodule JumpAgent.AI.Instruction do
  use JumpAgent.Schema
  alias JumpAgent.Accounts.User

  @valid_instruction_types ["ongoing", "temporary"]
  @valid_trigger_types ["email_received", "calendar_event_created", "hubspot_contact_created",
    "hubspot_contact_updated", "manual", "scheduled"]

  schema "ai_instructions" do
    field :instruction_type, :string, default: "ongoing"
    field :trigger_type, :string, default: "manual"
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
    |> validate_instruction_type()
    |> validate_trigger_type_simple()
    |> foreign_key_constraint(:user_id)
  end

  defp validate_instruction_type(changeset) do
    type = get_field(changeset, :instruction_type)

    if type in ["ongoing", "temporary"] do
      changeset
    else
      add_error(changeset, :instruction_type, "must be ongoing or temporary")
    end
  end

  defp validate_trigger_type_simple(changeset) do
    type = get_field(changeset, :trigger_type)

    # Set default if empty
    changeset =
      if is_nil(type) or type == "" do
        put_change(changeset, :trigger_type, "manual")
      else
        changeset
      end

    # Now validate
    current_type = get_field(changeset, :trigger_type)

    valid_types = [
      "manual",
      "email_received",
      "calendar_event_created",
      "hubspot_contact_created",
      "hubspot_contact_updated",
      "scheduled"
    ]

    if current_type in valid_types do
      changeset
    else
      add_error(changeset, :trigger_type, "is invalid")
    end
  end
end

