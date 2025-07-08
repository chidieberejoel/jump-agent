defmodule JumpAgentWeb.LiveAuth do
  @moduledoc """
  Helpers for LiveView authentication
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]
  alias JumpAgent.Accounts
  require Logger

  def on_mount(:require_authenticated_user, _params, session, socket) do
    socket = assign_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      Logger.warning("Unauthenticated LiveView access attempt")

      socket =
        socket
        |> put_flash(:error, "You must log in to access this page.")
        |> redirect(to: "/")

      {:halt, socket}
    end
  end

  def on_mount(:optional_authenticated_user, _params, session, socket) do
    {:cont, assign_current_user(socket, session)}
  end

  defp assign_current_user(socket, session) do
    case session do
      %{"user_id" => user_id} when is_binary(user_id) ->
        case Accounts.get_user(user_id) do
          nil ->
            Logger.warning("User #{user_id} not found in database")
            assign(socket, :current_user, nil)

          user ->
            socket
            |> assign(:current_user, user)
            |> assign(:user_token, user_id)
        end

      _ ->
        assign(socket, :current_user, nil)
    end
  end
end