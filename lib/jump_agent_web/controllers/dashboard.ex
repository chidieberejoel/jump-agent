defmodule JumpAgentWeb.DashboardController do
  use JumpAgentWeb, :controller
  alias JumpAgent.HubSpot

  def index(conn, _params) do
    user = conn.assigns.current_user
    hubspot_connection = HubSpot.get_connection_by_user(user)

    render(conn, :index, hubspot_connection: hubspot_connection)
  end
end
