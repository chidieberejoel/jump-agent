defmodule JumpAgentWeb.ChatLive do
  use JumpAgentWeb, :live_view

  alias JumpAgent.AI
  alias JumpAgent.AI.{Conversation, Message}

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    if user do
      Logger.info("ChatLive mounting for user #{user.id}")

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
        |> assign(:error_message, nil)}
    else
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
        |> assign(:error_message, nil)}
    end
  end

  @impl true
  def handle_event("send_message", %{"message" => message}, socket) when message != "" do
    user = socket.assigns.current_user
    conversation = socket.assigns.current_conversation

    # Create user message
    {:ok, user_message} = AI.create_message(conversation, %{
      role: "user",
      content: message
    })

    # Create new messages list (important for change detection)
    new_messages = socket.assigns.messages ++ [user_message]

    # Update socket and start async processing
    socket =
      socket
      |> assign(:messages, new_messages)
      |> assign(:message_input, "")
      |> assign(:is_typing, true)
      |> assign(:error_message, nil)
      |> start_async(:process_ai_message, fn ->
        # This runs in a separate process
        Logger.info("Processing message async for conversation #{conversation.id}")
        AI.process_user_message(conversation, message)
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("send_message", _params, socket) do
    {:noreply, socket}
  end

  # Handle successful AI response
  @impl true
  def handle_async(:process_ai_message, {:ok, {:ok, ai_message}}, socket) do
    Logger.info("AI response received successfully")

    # Add the AI message to the list
    updated_messages = socket.assigns.messages ++ [ai_message]

    {:noreply,
      socket
      |> assign(:messages, updated_messages)
      |> assign(:is_typing, false)
      |> assign(:error_message, nil)}
  end

  # Handle AI processing error
  @impl true
  def handle_async(:process_ai_message, {:ok, {:error, reason}}, socket) do
    Logger.error("AI processing failed: #{inspect(reason)}")

    error_msg = format_error_message(reason)

    {:noreply,
      socket
      |> assign(:is_typing, false)
      |> assign(:error_message, error_msg)}
  end

  # Handle process crash/exit
  @impl true
  def handle_async(:process_ai_message, {:exit, reason}, socket) do
    Logger.error("AI processing crashed: #{inspect(reason)}")

    {:noreply,
      socket
      |> assign(:is_typing, false)
      |> assign(:error_message, "The AI service encountered an error. Please try again.")}
  end

  # UI Event Handlers

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :show_chat_modal, false)}
  end

  @impl true
  def handle_event("open_modal", _params, socket) do
    {:noreply, assign(socket, :show_chat_modal, true)}
  end

  @impl true
  def handle_event("update_message", %{"message" => message}, socket) do
    {:noreply, assign(socket, :message_input, message)}
  end

  @impl true
  def handle_event("dismiss_error", _params, socket) do
    {:noreply, assign(socket, :error_message, nil)}
  end

  @impl true
  def handle_event("switch_tab", params, socket) do
    tab = Map.get(params, "tab", "chat")
    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_event("new_thread", _params, socket) do
    user = socket.assigns.current_user

    # Create new conversation
    {:ok, conversation} = AI.create_conversation(user, %{
      title: "New Conversation",
      context: %{"source" => socket.assigns.context_source}
    })

    # Add to beginning of conversations list
    conversations = [conversation | socket.assigns.conversations]

    {:noreply,
      socket
      |> assign(:conversations, conversations)
      |> assign(:current_conversation, conversation)
      |> assign(:messages, [])
      |> assign(:message_input, "")
      |> assign(:error_message, nil)}
  end

  @impl true
  def handle_event("select_conversation", %{"id" => conv_id}, socket) do
    # Load conversation asynchronously to avoid blocking UI
    socket =
      socket
      |> assign(:loading_conversation, true)
      |> start_async(:load_conversation, fn ->
        user = socket.assigns.current_user
        conversation = AI.get_conversation!(user, conv_id)
        messages = AI.list_messages(conversation)
        {conversation, messages}
      end)

    {:noreply, socket}
  end

  # Handle async conversation loading
  @impl true
  def handle_async(:load_conversation, {:ok, {conversation, messages}}, socket) do
    {:noreply,
      socket
      |> assign(:current_conversation, conversation)
      |> assign(:messages, messages)
      |> assign(:loading_conversation, false)
      |> assign(:error_message, nil)}
  end

  @impl true
  def handle_async(:load_conversation, {:exit, _reason}, socket) do
    {:noreply,
      socket
      |> assign(:loading_conversation, false)
      |> assign(:error_message, "Failed to load conversation")}
  end

  @impl true
  def handle_event("change_context", %{"context" => context}, socket) do
    # Update conversation context
    conversation = socket.assigns.current_conversation

    {:ok, updated_conv} = AI.update_conversation(conversation, %{
      context: Map.put(conversation.context || %{}, "source", context)
    })

    {:noreply,
      socket
      |> assign(:current_conversation, updated_conv)
      |> assign(:context_source, context)}
  end

  @impl true
  def handle_event("delete_conversation", %{"id" => conv_id}, socket) do
    user = socket.assigns.current_user

    # Delete asynchronously
    socket = start_async(socket, :delete_conversation, fn ->
      conversation = AI.get_conversation!(user, conv_id)
      {:ok, _} = AI.delete_conversation(conversation)
      conv_id
    end)

    {:noreply, socket}
  end

  # Handle async deletion
  @impl true
  def handle_async(:delete_conversation, {:ok, deleted_id}, socket) do
    # Remove from conversations list
    conversations = Enum.reject(socket.assigns.conversations, &(&1.id == deleted_id))

    # If we deleted the current conversation, switch to another or create new
    socket = if socket.assigns.current_conversation.id == deleted_id do
      case conversations do
        [first | _] ->
          # Load the first conversation
          messages = AI.list_messages(first)
          socket
          |> assign(:current_conversation, first)
          |> assign(:messages, messages)
          |> assign(:conversations, conversations)

        [] ->
          # Create a new conversation if none left
          user = socket.assigns.current_user
          {:ok, new_conv} = AI.create_conversation(user, %{
            title: "New Conversation",
            context: %{"source" => socket.assigns.context_source}
          })
          socket
          |> assign(:conversations, [new_conv])
          |> assign(:current_conversation, new_conv)
          |> assign(:messages, [])
      end
    else
      assign(socket, :conversations, conversations)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_async(:delete_conversation, {:exit, _reason}, socket) do
    {:noreply, assign(socket, :error_message, "Failed to delete conversation")}
  end

  # Handle other info messages (like clear_flash)
  @impl true
  def handle_info(:clear_flash, socket) do
    {:noreply, clear_flash(socket)}
  end

  defp format_error_message(:no_api_key), do: "OpenAI API key not configured. Please set OPENAI_API_KEY."
  defp format_error_message(msg) when is_binary(msg), do: msg
  defp format_error_message(error), do: "An error occurred: #{inspect(error)}"

  # Incase delete_conversation is to be implemented
  #  @impl true
#  def handle_event("delete_conversation", %{"id" => conv_id}, socket) do
#    user = socket.assigns.current_user
#    conversation = AI.get_conversation!(user, conv_id)
#
#    {:ok, _} = AI.delete_conversation(conversation)
#
#    # Remove from conversations list
#    conversations = Enum.reject(socket.assigns.conversations, &(&1.id == conv_id))
#
#    # If we deleted the current conversation, switch to another or create new
#    socket = if socket.assigns.current_conversation.id == conv_id do
#      case conversations do
#        [first | _] ->
#          messages = AI.list_messages(first)
#          socket
#          |> assign(:current_conversation, first)
#          |> assign(:messages, messages)
#        [] ->
#          # Create a new conversation if none left
#          {:ok, new_conv} = AI.create_conversation(user, %{
#            title: "New Conversation",
#            context: %{"source" => socket.assigns.context_source}
#          })
#          socket
#          |> assign(:conversations, [new_conv])
#          |> assign(:current_conversation, new_conv)
#          |> assign(:messages, [])
#      end
#    else
#      assign(socket, :conversations, conversations)
#    end
#
#    {:noreply, socket}
#  end

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
            <h2 class="text-lg font-semibold">AI Assistant</h2>
            <button
              phx-click="close_modal"
              class="text-gray-400 hover:text-gray-500"
            >
              <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"></path>
              </svg>
            </button>
          </div>

          <!-- Error Banner -->
          <div :if={@error_message} class="bg-red-50 border-b border-red-200 px-4 py-3">
            <div class="flex items-start">
              <div class="flex-shrink-0">
                <svg class="h-5 w-5 text-red-400" fill="currentColor" viewBox="0 0 20 20">
                  <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z" clip-rule="evenodd" />
                </svg>
              </div>
              <div class="ml-3 flex-1">
                <p class="text-sm text-red-700">
                  <%= @error_message %>
                </p>
              </div>
              <div class="ml-auto pl-3">
                <button
                  phx-click="dismiss_error"
                  class="inline-flex text-red-400 hover:text-red-500"
                >
                  <svg class="h-5 w-5" fill="currentColor" viewBox="0 0 20 20">
                    <path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd" />
                  </svg>
                </button>
              </div>
            </div>
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
                  Context: <%= @context_source %>
                  <span class="text-gray-400 ml-2">
                    <%= Calendar.strftime(@current_conversation.inserted_at, "%I:%M%P - %b %d, %Y") %>
                  </span>
                </div>

                <!-- Messages -->
                <div id="messages-container" phx-hook="MessageList" class="flex-1 overflow-y-auto p-4 space-y-2">
                  <%= if @messages == [] do %>
                    <!-- Empty state -->
                    <div class="text-center text-gray-500 mt-8">
                      <p class="text-lg font-medium mb-2">
                        Start a conversation
                      </p>
                      <p class="text-sm">
                        I'm your AI assistant. I can help you search emails, manage contacts, schedule meetings, and more.
                      </p>
                    </div>
                    <% end %>

                    <%= for message <- @messages do %>
                    <div id={"message-#{message.id}"} class={"flex #{if message.role == "user", do: "justify-end", else: "justify-start"}"}>
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
                        placeholder="Type your message..."
                        class="w-full px-3 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-brand resize-none"
                        rows="2"
                        disabled={@is_typing}
                      ></textarea>
                    </div>
                    <div class="flex items-center space-x-2">
                      <button
                        type="submit"
                        class="p-2 text-gray-500 hover:text-gray-700 disabled:opacity-50"
                        disabled={@is_typing}
                      >
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
              <div class="p-4 space-y-2 overflow-y-auto">
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
