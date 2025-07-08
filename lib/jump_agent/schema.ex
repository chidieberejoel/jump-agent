defmodule JumpAgent.Schema do
  @moduledoc """
  Base schema module that configures UUID primary keys and foreign keys
  for all schemas in the application.

  ## Usage

  Instead of `use Ecto.Schema`, use `use JumpAgent.Schema`:

      defmodule JumpAgent.Blog.Post do
        use JumpAgent.Schema

        schema "posts" do
          field :title, :string
          field :body, :text
          belongs_to :user, JumpAgent.Accounts.User

          timestamps()
        end
      end

  This automatically configures:
  - UUID primary keys (binary_id)
  - UUID foreign keys (binary_id)
  - UTC datetime timestamps
  """

  defmacro __using__(_) do
    quote do
      use Ecto.Schema
      import Ecto.Changeset

      # Configure UUID primary keys
      @primary_key {:id, :binary_id, autogenerate: true}

      # Configure UUID foreign keys
      @foreign_key_type :binary_id

      # Configure UTC timestamps
      @timestamps_opts [type: :utc_datetime]
    end
  end
end
