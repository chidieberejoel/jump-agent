defmodule JumpAgent.Repo do
  use Ecto.Repo,
    otp_app: :jump_agent,
    adapter: Ecto.Adapters.Postgres
end
