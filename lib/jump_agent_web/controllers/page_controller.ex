defmodule JumpAgentWeb.PageController do
  use JumpAgentWeb, :controller

  def home(conn, _params) do
    # The home page is often custom made,
    # so skip the default app layout.

    # The redirect_if_auth plug should handle authenticated users,
    # but we pass current_user as a safeguard
    render(conn, :home,
      layout: false,
      current_user: conn.assigns[:current_user]
    )
  end

  def not_found(conn, _params) do
    conn
    |> put_status(:not_found)
    |> put_view(JumpAgentWeb.ErrorHTML)
    |> render("404.html")
  end
end
