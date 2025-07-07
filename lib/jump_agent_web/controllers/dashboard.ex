defmodule JumpAgentWeb.DashboardController do
  use JumpAgentWeb, :controller

  def index(conn, _params) do
    render(conn, :index)
  end
end
