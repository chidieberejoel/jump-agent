defmodule JumpAgentWeb.DashboardLive do
  use JumpAgentWeb, :live_view

  alias JumpAgent.GoogleAPI

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:gmail_profile, nil)
      |> assign(:calendars, nil)
      |> assign(:recent_emails, [])
      |> assign(:loading_gmail, false)
      |> assign(:loading_calendars, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("load_gmail", _params, socket) do
    socket = assign(socket, :loading_gmail, true)
    user = socket.assigns.current_user

    case GoogleAPI.get_gmail_profile(user) do
      {:ok, profile} ->
        # Also fetch recent emails
        emails_result = GoogleAPI.list_emails(user, maxResults: 5)

        {:noreply,
          socket
          |> assign(:gmail_profile, profile)
          |> assign(:recent_emails, elem(emails_result, 1)["messages"] || [])
          |> assign(:loading_gmail, false)}

      {:error, :unauthorized} ->
        {:noreply,
          socket
          |> put_flash(:error, "Gmail access expired. Please log in again.")
          |> assign(:loading_gmail, false)}

      {:error, {:rate_limited, retry_after}} ->
        {:noreply,
          socket
          |> put_flash(:error, "Gmail API rate limit reached. Please try again in #{retry_after} seconds.")
          |> assign(:loading_gmail, false)}

      {:error, _reason} ->
        {:noreply,
          socket
          |> put_flash(:error, "Failed to load Gmail profile. Please try again later.")
          |> assign(:loading_gmail, false)}
    end
  end

  @impl true
  def handle_event("load_calendars", _params, socket) do
    socket = assign(socket, :loading_calendars, true)
    user = socket.assigns.current_user

    case GoogleAPI.list_calendars(user) do
      {:ok, %{"items" => calendars}} ->
        {:noreply,
          socket
          |> assign(:calendars, calendars)
          |> assign(:loading_calendars, false)}

      {:error, :unauthorized} ->
        {:noreply,
          socket
          |> put_flash(:error, "Calendar access expired. Please log in again.")
          |> assign(:loading_calendars, false)}

      {:error, {:rate_limited, retry_after}} ->
        {:noreply,
          socket
          |> put_flash(:error, "Calendar API rate limit reached. Please try again in #{retry_after} seconds.")
          |> assign(:loading_calendars, false)}

      {:error, _reason} ->
        {:noreply,
          socket
          |> put_flash(:error, "Failed to load calendars. Please try again later.")
          |> assign(:loading_calendars, false)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-4xl">
      <.header>
        Dashboard
        <:subtitle>
          Welcome back, <%= @current_user.name || @current_user.email %>!
        </:subtitle>
      </.header>

      <div class="mt-8 grid grid-cols-1 gap-6 sm:grid-cols-2">
        <!-- Gmail Card -->
        <div class="bg-white overflow-hidden shadow rounded-lg">
          <div class="px-4 py-5 sm:p-6">
            <div class="flex items-center">
              <div class="flex-shrink-0">
                <svg class="h-8 w-8 text-red-600" fill="currentColor" viewBox="0 0 24 24">
                  <path d="M20 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2zm0 4l-8 5-8-5V6l8 5 8-5v2z"/>
                </svg>
              </div>
              <div class="ml-5 w-0 flex-1">
                <dl>
                  <dt class="text-sm font-medium text-gray-500 truncate">
                    Gmail
                  </dt>
                  <dd>
                    <div class="text-lg font-medium text-gray-900">
                      <%= if @gmail_profile do %>
                        <%= @gmail_profile["messagesTotal"] || 0 %> total messages
                      <% else %>
                        Click to load
                      <% end %>
                    </div>
                  </dd>
                </dl>
              </div>
            </div>
            <div class="mt-5">
              <button
                phx-click="load_gmail"
                disabled={@loading_gmail}
                class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-red-600 hover:bg-red-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-red-500 disabled:opacity-50"
              >
                <%= if @loading_gmail do %>
                  Loading...
                <% else %>
                  Load Gmail Info
                <% end %>
              </button>
            </div>
          </div>
        </div>

        <!-- Calendar Card -->
        <div class="bg-white overflow-hidden shadow rounded-lg">
          <div class="px-4 py-5 sm:p-6">
            <div class="flex items-center">
              <div class="flex-shrink-0">
                <svg class="h-8 w-8 text-blue-600" fill="currentColor" viewBox="0 0 24 24">
                  <path d="M19 3h-1V1h-2v2H8V1H6v2H5c-1.11 0-1.99.9-1.99 2L3 19c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm0 16H5V8h14v11zM7 10h5v5H7z"/>
                </svg>
              </div>
              <div class="ml-5 w-0 flex-1">
                <dl>
                  <dt class="text-sm font-medium text-gray-500 truncate">
                    Google Calendar
                  </dt>
                  <dd>
                    <div class="text-lg font-medium text-gray-900">
                      <%= if @calendars do %>
                        <%= length(@calendars) %> calendars
                      <% else %>
                        Click to load
                      <% end %>
                    </div>
                  </dd>
                </dl>
              </div>
            </div>
            <div class="mt-5">
              <button
                phx-click="load_calendars"
                disabled={@loading_calendars}
                class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-blue-600 hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500 disabled:opacity-50"
              >
                <%= if @loading_calendars do %>
                  Loading...
                <% else %>
                  Load Calendars
                <% end %>
              </button>
            </div>
          </div>
        </div>
      </div>

      <!-- Calendar List -->
      <%= if @calendars do %>
        <div class="mt-8">
          <h3 class="text-lg leading-6 font-medium text-gray-900">
            Your Calendars
          </h3>
          <div class="mt-4 bg-white shadow overflow-hidden sm:rounded-md">
            <ul class="divide-y divide-gray-200">
              <%= for calendar <- @calendars do %>
                <li class="px-4 py-4 sm:px-6">
                  <div class="flex items-center justify-between">
                    <div class="flex items-center">
                      <div class="flex-shrink-0">
                        <div
                          class="h-3 w-3 rounded-full"
                          style={"background-color: #{calendar["backgroundColor"]}"}
                        ></div>
                      </div>
                      <div class="ml-4">
                        <div class="text-sm font-medium text-gray-900">
                          <%= calendar["summary"] %>
                        </div>
                        <div class="text-sm text-gray-500">
                          <%= calendar["id"] %>
                        </div>
                      </div>
                    </div>
                    <div class="ml-2 flex-shrink-0 flex">
                      <%= if calendar["primary"] do %>
                        <span class="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-green-100 text-green-800">
                          Primary
                        </span>
                      <% end %>
                    </div>
                  </div>
                </li>
              <% end %>
            </ul>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
