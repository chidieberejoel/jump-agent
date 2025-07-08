defmodule JumpAgentWeb.DashboardLive do
  use JumpAgentWeb, :live_view

  alias JumpAgent.GoogleAPI
  alias JumpAgent.{HubSpot, HubSpotAPI}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    hubspot_connection = HubSpot.get_connection_by_user(user)

    socket =
      socket
      |> assign(:gmail_profile, nil)
      |> assign(:calendars, nil)
      |> assign(:recent_emails, [])
      |> assign(:loading_gmail, false)
      |> assign(:loading_calendars, false)
      |> assign(:hubspot_connection, hubspot_connection)
      |> assign(:hubspot_contacts, [])
      |> assign(:hubspot_owners, [])
      |> assign(:loading_hubspot, false)

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
  def handle_event("load_hubspot", _params, socket) do
    if socket.assigns.hubspot_connection do
      socket = assign(socket, :loading_hubspot, true)
      connection = socket.assigns.hubspot_connection

      # Fetch contacts with better error handling
      contacts_task = Task.async(fn ->
        HubSpotAPI.list_contacts(connection, limit: 10, properties: "firstname,lastname,email,company,lifecyclestage,phone")
      end)

      # Fetch owners
      owners_task = Task.async(fn ->
        HubSpotAPI.list_owners(connection)
      end)

      # Wait for both with timeout
      contacts_result = Task.await(contacts_task, 10_000)
      owners_result = Task.await(owners_task, 10_000)

      case {contacts_result, owners_result} do
        {{:ok, %{"results" => contacts}}, {:ok, %{"results" => owners}}} ->
          {:noreply,
            socket
            |> assign(:hubspot_contacts, contacts)
            |> assign(:hubspot_owners, owners)
            |> assign(:loading_hubspot, false)}

        {{:error, :unauthorized}, _} ->
          {:noreply,
            socket
            |> put_flash(:error, "HubSpot access expired. Please reconnect your account.")
            |> assign(:loading_hubspot, false)
            |> push_navigate(to: ~p"/dashboard")}

        {_, _} ->
          {:noreply,
            socket
            |> put_flash(:error, "Failed to load HubSpot data. Please try again.")
            |> assign(:loading_hubspot, false)}
      end
    else
      {:noreply, put_flash(socket, :error, "Please connect your HubSpot account first.")}
    end
  rescue
    _ ->
      {:noreply,
        socket
        |> put_flash(:error, "Failed to load HubSpot data. Please try again.")
        |> assign(:loading_hubspot, false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl">
      <.header>
        Dashboard
        <:subtitle>
          Welcome back, <%= @current_user.name || @current_user.email %>!
        </:subtitle>
      </.header>

      <div class="mt-8 grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3">
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
                class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-red-600 hover:bg-red-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-red-500 disabled:opacity-50 disabled:cursor-not-allowed"
              >
                <%= if @loading_gmail do %>
                  <svg class="animate-spin -ml-1 mr-2 h-4 w-4 text-white" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                    <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                    <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                  </svg>
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
                class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-blue-600 hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500 disabled:opacity-50 disabled:cursor-not-allowed"
              >
                <%= if @loading_calendars do %>
                  <svg class="animate-spin -ml-1 mr-2 h-4 w-4 text-white" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                    <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                    <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                  </svg>
                  Loading...
                <% else %>
                  Load Calendars
                <% end %>
              </button>
            </div>
          </div>
        </div>

        <!-- HubSpot Card -->
        <div class="bg-white overflow-hidden shadow rounded-lg">
          <div class="px-4 py-5 sm:p-6">
            <div class="flex items-center">
              <div class="flex-shrink-0">
                <svg class="h-8 w-8 text-orange-500" fill="currentColor" viewBox="0 0 24 24">
                  <path d="M21.56 8.74l-4.24-1.13c.3-1.02.48-2.11.48-3.24C17.8 1.96 15.84 0 13.43 0c-1.57 0-2.95.84-3.71 2.09A7.96 7.96 0 006.2 0C3.49 0 1.29 2.2 1.29 4.91c0 .42.05.83.15 1.22L.24 6.43C.09 6.47 0 6.61 0 6.77v3.46c0 .16.09.3.24.34l1.45.38v2.28c0 .16.09.3.24.34l1.45.38v2.28c0 .16.09.3.24.34l4.96 1.32c.05.01.1.02.16.01.11 0 .21-.06.27-.16.08-.14.04-.32-.1-.41l-.94-.63c-.07-.05-.12-.12-.14-.2l-1.34-5.04 2.8.74c.05.01.1.02.16.01.11 0 .21-.06.27-.16.08-.14.04-.32-.1-.41l-.94-.63c-.07-.05-.12-.12-.14-.2L7.24 6.18c.69.41 1.49.65 2.35.65 1.57 0 2.95-.84 3.71-2.09.76 1.25 2.14 2.09 3.71 2.09.73 0 1.41-.19 2.01-.51v3.11l-1.04 4c-.02.08-.07.15-.14.2l-.94.63c-.14.09-.18.27-.1.41.06.1.16.16.27.16.06 0 .11 0 .16-.01l4.96-1.32c.15-.04.24-.18.24-.34V9.08c0-.16-.09-.3-.24-.34z"/>
                </svg>
              </div>
              <div class="ml-5 w-0 flex-1">
                <dl>
                  <dt class="text-sm font-medium text-gray-500 truncate">
                    HubSpot CRM
                  </dt>
                  <dd>
                    <div class="text-lg font-medium text-gray-900">
                      <%= if @hubspot_connection do %>
                        <%= if @hubspot_contacts != [], do: "#{length(@hubspot_contacts)} contacts", else: "Connected" %>
                      <% else %>
                        Not connected
                      <% end %>
                    </div>
                  </dd>
                </dl>
              </div>
            </div>
            <div class="mt-5">
              <%= if @hubspot_connection do %>
                <button
                  phx-click="load_hubspot"
                  disabled={@loading_hubspot}
                  class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-orange-600 hover:bg-orange-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-orange-500 disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  <%= if @loading_hubspot do %>
                    <svg class="animate-spin -ml-1 mr-2 h-4 w-4 text-white" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                      <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                    </svg>
                    Loading...
                  <% else %>
                    Load HubSpot Data
                  <% end %>
                </button>
              <% else %>
                <.link
                  href={~p"/hubspot/connect"}
                  class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-orange-600 hover:bg-orange-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-orange-500"
                >
                  Connect HubSpot
                </.link>
              <% end %>
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

      <!-- HubSpot Contacts (Read-only) -->
      <%= if @hubspot_connection && @hubspot_contacts != [] do %>
        <div class="mt-8">
          <h3 class="text-lg leading-6 font-medium text-gray-900">
            HubSpot Contacts
          </h3>
          <div class="mt-4 bg-white shadow overflow-hidden sm:rounded-md">
            <ul class="divide-y divide-gray-200">
              <%= for contact <- @hubspot_contacts do %>
                <li class="px-4 py-4 sm:px-6">
                  <div class="flex items-center justify-between">
                    <div class="flex items-center">
                      <div class="flex-shrink-0">
                        <div class="h-10 w-10 rounded-full bg-gray-300 flex items-center justify-center">
                          <span class="text-gray-600 font-medium text-sm">
                            <%= String.first(contact["properties"]["firstname"] || contact["properties"]["lastname"] || "?") %>
                          </span>
                        </div>
                      </div>
                      <div class="ml-4">
                        <div class="text-sm font-medium text-gray-900">
                          <%= contact["properties"]["firstname"] || "" %> <%= contact["properties"]["lastname"] || "" %>
                          <%= if !contact["properties"]["firstname"] && !contact["properties"]["lastname"] do %>
                            <span class="text-gray-500">No name</span>
                          <% end %>
                        </div>
                        <div class="text-sm text-gray-500">
                          <%= contact["properties"]["email"] || "No email" %>
                        </div>
                        <%= if contact["properties"]["company"] do %>
                          <p class="text-xs text-gray-500 mt-1">
                            <%= contact["properties"]["company"] %>
                          </p>
                        <% end %>
                      </div>
                    </div>
                    <div class="flex items-center">
                      <span class={"px-2 inline-flex text-xs leading-5 font-semibold rounded-full " <> lifecycle_stage_color(contact["properties"]["lifecyclestage"])}>
                        <%= humanize_lifecycle_stage(contact["properties"]["lifecyclestage"]) %>
                      </span>
                    </div>
                  </div>
                </li>
              <% end %>
            </ul>
          </div>
        </div>
      <% end %>

      <!-- HubSpot Owners -->
      <%= if @hubspot_owners != [] do %>
        <div class="mt-8">
          <h3 class="text-lg leading-6 font-medium text-gray-900">
            HubSpot Team Members
          </h3>
          <div class="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
            <%= for owner <- @hubspot_owners do %>
              <div class="bg-white overflow-hidden shadow rounded-lg">
                <div class="px-4 py-5 sm:p-6">
                  <div class="flex items-center">
                    <div class="flex-shrink-0">
                      <div class="h-10 w-10 rounded-full bg-gray-300 flex items-center justify-center">
                        <span class="text-gray-600 font-medium">
                          <%= String.first(owner["firstName"] || "?") %><%= String.first(owner["lastName"] || "?") %>
                        </span>
                      </div>
                    </div>
                    <div class="ml-4">
                      <div class="text-sm font-medium text-gray-900">
                        <%= owner["firstName"] %> <%= owner["lastName"] %>
                      </div>
                      <div class="text-sm text-gray-500">
                        <%= owner["email"] %>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # Helper functions
  defp lifecycle_stage_color(stage) do
    case stage do
      "lead" -> "bg-gray-100 text-gray-800"
      "marketingqualifiedlead" -> "bg-blue-100 text-blue-800"
      "salesqualifiedlead" -> "bg-indigo-100 text-indigo-800"
      "opportunity" -> "bg-yellow-100 text-yellow-800"
      "customer" -> "bg-green-100 text-green-800"
      "evangelist" -> "bg-purple-100 text-purple-800"
      _ -> "bg-gray-100 text-gray-800"
    end
  end

  defp humanize_lifecycle_stage(stage) do
    case stage do
      "lead" -> "Lead"
      "marketingqualifiedlead" -> "MQL"
      "salesqualifiedlead" -> "SQL"
      "opportunity" -> "Opportunity"
      "customer" -> "Customer"
      "evangelist" -> "Evangelist"
      _ -> "Unknown"
    end
  end
end
