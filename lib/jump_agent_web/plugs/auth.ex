defmodule JumpAgentWeb.Plugs.Auth do
  import Plug.Conn
  import Phoenix.Controller
  require Logger

  alias JumpAgent.Accounts

  def fetch_current_user(conn, _opts) do
    with user_id when is_binary(user_id) <- get_session(conn, :user_id),
         %Accounts.User{} = user <- Accounts.get_user(user_id) do
      assign(conn, :current_user, user)
    else
      _ -> assign(conn, :current_user, nil)
    end
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      Logger.warning("Unauthenticated access attempt to #{conn.request_path}")

      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> redirect(to: "/")
      |> halt()
    end
  end

  def redirect_if_authenticated(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
      |> redirect(to: "/dashboard")
      |> halt()
    else
      conn
    end
  end

  @doc """
  Used for API endpoints that require authentication
  """
  def require_api_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_status(:unauthorized)
      |> put_view(JumpAgentWeb.ErrorJSON)
      |> render(:"401")
      |> halt()
    end
  end
end
