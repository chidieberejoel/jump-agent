defmodule JumpAgentWeb.ChatLive do
  use JumpAgentWeb, :live_view

  alias JumpAgent.AI
  alias JumpAgent.AI.{Conversation, Message}
  alias Phoenix.LiveView.AsyncResult

  @impl true
  def mount(_params, _session, socket) do
    # current_user is set by the on_mount hook
    user = socket.assigns[:current_user]

    # If user is not set, the on_mount hook will redirect
    if user do
      # Load conversations
      conversations = AI.list_conversations(user)

      # Create or get the most recent conversation
      current_conversation =
        case conversations do
          [conv | _] -> conv
          [] ->
            {:ok, conv} = AI.create_conversation(user, %{
              title: "New Conversation",
              context: %{"source" => "all_meetings"}
            })
            conv
        end

      # Load messages for current conversation (limit to prevent memory issues)
      messages = AI.list_messages(current_conversation, limit: 50)

      {:ok,
        socket
        |> assign(:conversations, conversations)
        |> assign(:current_conversation, current_conversation)
        |> assign(:messages, messages)
        |> assign(:message_input, "")
        |> assign(:is_typing, false)
        |> assign(:show_chat_modal, true)
        |> assign(:active_tab, "chat")
        |> assign(:context_source, "all_meetings")
        |> assign(:processing_message, AsyncResult.ok(nil))}
    else
      # This should not happen as on_mount should handle authentication
      # But we need to provide default assigns for the template
      {:ok,
        socket
        |> assign(:conversations, [])
        |> assign(:current_conversation, nil)
        |> assign(:messages, [])
        |> assign(:message_input, "")
        |> assign(:is_typing, false)
        |> assign(:show_chat_modal, false)
        |> assign(:active_tab, "chat")
        |> assign(:context_source, "all_meetings")
        |> assign(:processing_message, AsyncResult.ok(nil))}
    end
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :show_chat_modal, false)}
  end

  @impl true
  def handle_event("open_modal", _params, socket) do
    {:noreply, assign(socket, :show_chat_modal, true)}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_event("new_thread", _params, socket) do
    user = socket.assigns.current_user

    {:ok, conversation} = AI.create_conversation(user, %{
      title: "New Conversation",
      context: %{"source" => socket.assigns.context_source}
    })

    conversations = [conversation | socket.assigns.conversations]

    {:noreply,
      socket
      |> assign(:conversations, conversations)
      |> assign(:current_conversation, conversation)
      |> assign(:messages, [])
      |> assign(:message_input, "")}
  end

  @impl true
  def handle_event("select_conversation", %{"id" => conv_id}, socket) do
    user = socket.assigns.current_user
    conversation = AI.get_conversation!(user, conv_id)
    messages = AI.list_messages(conversation)

    {:noreply,
      socket
      |> assign(:current_conversation, conversation)
      |> assign(:messages, messages)}
  end

  @impl true
  def handle_event("update_message", %{"message" => message}, socket) do
    {:noreply, assign(socket, :message_input, message)}
  end

  @impl true
  def handle_event("send_message", %{"message" => message}, socket) when message != "" do
    user = socket.assigns.current_user

    # Check rate limit (30 messages per minute)
#    case JumpAgent.RateLimiter.check_rate("chat:#{user.id}", 30) do
#      {:ok, _remaining} ->
        conversation = socket.assigns.current_conversation

        # Create user message
        {:ok, user_message} = AI.create_message(conversation, %{
          role: "user",
          content: message
        })

        # Add to messages list
        messages = socket.assigns.messages ++ [user_message]

        # Start async processing
        socket =
          socket
          |> assign(:messages, messages)
          |> assign(:message_input, "")
          |> assign(:is_typing, true)
          |> assign_async(:processing_message, fn ->
            process_message(conversation, message)
          end)

        {:noreply, socket}

#      {:error, {:rate_limited, reset_in}} ->
#        {:noreply,
#          socket
#          |> put_flash(:error, "You're sending messages too quickly. Please wait #{ceil(reset_in / 1000)} seconds.")
#          |> clear_flash_after(5000)}
#    end
  end

  @impl true
  def handle_event("send_message", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("change_context", %{"context" => context}, socket) do
    # Update conversation context
    conversation = socket.assigns.current_conversation

    {:ok, updated_conv} = AI.update_conversation(conversation, %{
      context: Map.put(conversation.context, "source", context)
    })

    {:noreply,
      socket
      |> assign(:current_conversation, updated_conv)
      |> assign(:context_source, context)}
  end

  @impl true
  def handle_async(:processing_message, {:ok, ai_message}, socket) do
    messages = socket.assigns.messages ++ [ai_message]

    {:noreply,
      socket
      |> assign(:messages, messages)
      |> assign(:is_typing, false)}
  end

  @impl true
  def handle_async(:processing_message, {:error, _reason}, socket) do
    # Create error message
    error_message = %Message{
      id: Ecto.UUID.generate(),
      role: "assistant",
      content: "I'm having trouble processing your request. Please try again.",
      conversation_id: socket.assigns.current_conversation.id,
      user_id: socket.assigns.current_user.id,
      inserted_at: DateTime.utc_now()
    }

    messages = socket.assigns.messages ++ [error_message]

    {:noreply,
      socket
      |> assign(:messages, messages)
      |> assign(:is_typing, false)}
  end

  defp process_message(conversation, message) do
    case AI.process_user_message(conversation, message) do
      {:ok, ai_message} -> ai_message
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear_flash_after(socket, delay) do
    if socket.assigns[:flash_timer], do: Process.cancel_timer(socket.assigns.flash_timer)
    timer = Process.send_after(self(), :clear_flash, delay)
    assign(socket, :flash_timer, timer)
  end

  @impl true
  def handle_info(:clear_flash, socket) do
    {:noreply, clear_flash(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="relative">
      <!-- Chat Button (when modal is closed) -->
      <button
        :if={!@show_chat_modal}
        phx-click="open_modal"
        class="fixed bottom-6 right-6 bg-brand hover:bg-brand/90 text-white rounded-full p-4 shadow-lg z-50"
      >
        <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 10h.01M12 10h.01M16 10h.01M9 16H5a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v8a2 2 0 01-2 2h-5l-5 5v-5z"></path>
        </svg>
      </button>

      <!-- Chat Modal -->
      <div
        :if={@show_chat_modal}
        class="fixed inset-0 z-50 flex items-end justify-end p-4 sm:p-6"
      >
        <!-- Backdrop -->
        <div class="fixed inset-0 bg-black bg-opacity-25" phx-click="close_modal"></div>

        <!-- Modal Content -->
        <div class="relative bg-white rounded-lg shadow-xl w-full max-w-md h-[600px] flex flex-col">
          <!-- Header -->
          <div class="flex items-center justify-between p-4 border-b">
            <h2 class="text-lg font-semibold">Ask Anything</h2>
            <button
              phx-click="close_modal"
              class="text-gray-400 hover:text-gray-500"
            >
              <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"></path>
              </svg>
            </button>
          </div>

          <!-- Tabs -->
          <div class="flex border-b">
            <button
              phx-click="switch_tab"
              phx-value-tab="chat"
              class={"flex-1 py-2 px-4 text-sm font-medium #{if @active_tab == "chat", do: "text-brand border-b-2 border-brand", else: "text-gray-500"}"}
            >
              Chat
            </button>
            <button
              phx-click="switch_tab"
              phx-value-tab="history"
              class={"flex-1 py-2 px-4 text-sm font-medium #{if @active_tab == "history", do: "text-brand border-b-2 border-brand", else: "text-gray-500"}"}
            >
              History
            </button>
            <button
              phx-click="new_thread"
              class="px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 flex items-center gap-2"
            >
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4"></path>
              </svg>
              New thread
            </button>
          </div>

          <!-- Content Area -->
          <div class="flex-1 overflow-hidden">
            <%= if @active_tab == "chat" do %>
              <!-- Chat View -->
              <div class="flex flex-col h-full">
                <!-- Context Banner -->
                <div class="px-4 py-2 bg-gray-50 text-sm text-gray-600">
                  Context set to <%= @context_source %>
                  <span class="text-gray-400 ml-2">
                    <%= Calendar.strftime(@current_conversation.inserted_at, "%I:%M%P - %b %d, %Y") %>
                  </span>
                </div>

                <!-- Messages -->
                <div class="flex-1 overflow-y-auto px-4 py-4 space-y-4">
                  <%= if @messages == [] do %>
                    <div class="text-center text-gray-500 mt-8">
                      <p class="text-lg font-medium mb-2">
                        I can answer questions about any Jump meeting. What do you want to know?
                      </p>
                    </div>
                  <% end %>

                  <%= for message <- @messages do %>
                    <div class={"flex #{if message.role == "user", do: "justify-end", else: "justify-start"}"}>
                      <div class={"max-w-[80%] #{if message.role == "user", do: "bg-brand text-white", else: "bg-gray-100"} rounded-lg px-4 py-2"}>
                        <p class="text-sm whitespace-pre-wrap"><%= message.content %></p>
                      </div>
                    </div>
                  <% end %>

                  <%= if @is_typing do %>
                    <div class="flex justify-start">
                      <div class="bg-gray-100 rounded-lg px-4 py-2">
                        <div class="flex space-x-1">
                          <div class="w-2 h-2 bg-gray-400 rounded-full animate-bounce"></div>
                          <div class="w-2 h-2 bg-gray-400 rounded-full animate-bounce" style="animation-delay: 0.1s"></div>
                          <div class="w-2 h-2 bg-gray-400 rounded-full animate-bounce" style="animation-delay: 0.2s"></div>
                        </div>
                      </div>
                    </div>
                  <% end %>
                </div>

                <!-- Input Area -->
                <form phx-submit="send_message" class="border-t p-4">
                  <div class="flex items-end space-x-2">
                    <div class="flex-1">
                      <textarea
                        name="message"
                        value={@message_input}
                        phx-change="update_message"
                        placeholder="Ask anything about your meetings..."
                        class="w-full px-3 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-brand resize-none"
                        rows="2"
                      ></textarea>
                    </div>
                    <div class="flex items-center space-x-2">
                      <div class="relative">
                        <select
                          phx-change="change_context"
                          name="context"
                          class="appearance-none bg-gray-100 border border-gray-300 rounded-lg pl-3 pr-8 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-brand"
                        >
                          <option value="all_meetings" selected={@context_source == "all_meetings"}>All meetings</option>
                          <option value="gmail" selected={@context_source == "gmail"}>Gmail only</option>
                          <option value="hubspot" selected={@context_source == "hubspot"}>HubSpot only</option>
                          <option value="calendar" selected={@context_source == "calendar"}>Calendar only</option>
                        </select>
                        <div class="absolute inset-y-0 right-0 flex items-center pr-2 pointer-events-none">
                          <svg class="w-4 h-4 text-gray-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"></path>
                          </svg>
                        </div>
                      </div>
                      <button type="button" class="p-2 text-gray-500 hover:text-gray-700">
                        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m2.828 9.9a5 5 0 117.072 0l-.548.547A3.374 3.374 0 0014 18.469V19a2 2 0 11-4 0v-.531c0-.895-.356-1.754-.988-2.386l-.548-.547z"></path>
                        </svg>
                      </button>
                      <button type="submit" class="p-2 text-gray-500 hover:text-gray-700">
                        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 19l9 2-9-18-9 18 9-2zm0 0v-8"></path>
                        </svg>
                      </button>
                    </div>
                  </div>
                </form>
              </div>
            <% else %>
              <!-- History View -->
              <div class="p-4 space-y-2">
                <%= for conversation <- @conversations do %>
                  <button
                    phx-click="select_conversation"
                    phx-value-id={conversation.id}
                    class={"w-full text-left p-3 rounded-lg hover:bg-gray-50 #{if conversation.id == @current_conversation.id, do: "bg-gray-50 border border-gray-200", else: ""}"}
                  >
                    <div class="text-sm font-medium text-gray-900">
                      <%= conversation.title %>
                    </div>
                    <div class="text-xs text-gray-500 mt-1">
                      <%= Calendar.strftime(conversation.last_message_at || conversation.inserted_at, "%b %d, %Y at %I:%M %P") %>
                    </div>
                  </button>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
