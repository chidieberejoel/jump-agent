defmodule JumpAgentWeb.InstructionsLive do
  use JumpAgentWeb, :live_view

  alias JumpAgent.AI
  alias JumpAgent.AI.Instruction

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    instructions = AI.list_instructions(user)

    {:ok,
      socket
      |> assign(:instructions, instructions)
      |> assign(:show_form, false)
      |> assign(:form_mode, :new)
      |> assign(:editing_instruction, nil)
      |> assign_form(new_instruction_changeset())}
  end

  @impl true
  def handle_event("show_new_form", _params, socket) do
    {:noreply,
      socket
      |> assign(:show_form, true)
      |> assign(:form_mode, :new)
      |> assign(:editing_instruction, nil)
      |> assign_form(new_instruction_changeset())}
  end

  @impl true
  def handle_event("cancel_form", _params, socket) do
    {:noreply, assign(socket, :show_form, false)}
  end

  @impl true
  def handle_event("validate", %{"instruction" => params}, socket) do
    changeset =
      if socket.assigns.form_mode == :new do
        %Instruction{}
        |> Instruction.changeset(params)
        |> Map.put(:action, :validate)
      else
        socket.assigns.editing_instruction
        |> Instruction.changeset(params)
        |> Map.put(:action, :validate)
      end

    {:noreply, assign_form(socket, changeset)}
  end

  @impl true
  def handle_event("save", %{"instruction" => params}, socket) do
    user = socket.assigns.current_user
    params = Map.put(params, "user_id", user.id)

    result =
      if socket.assigns.form_mode == :new do
        AI.create_instruction(user, params)
      else
        AI.update_instruction(socket.assigns.editing_instruction, params)
      end

    case result do
      {:ok, _instruction} ->
        instructions = AI.list_instructions(user)

        {:noreply,
          socket
          |> assign(:instructions, instructions)
          |> assign(:show_form, false)
          |> put_flash(:info, "Instruction #{if socket.assigns.form_mode == :new, do: "created", else: "updated"} successfully")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    instruction = Enum.find(socket.assigns.instructions, &(&1.id == id))

    changeset = Instruction.changeset(instruction, %{})

    {:noreply,
      socket
      |> assign(:show_form, true)
      |> assign(:form_mode, :edit)
      |> assign(:editing_instruction, instruction)
      |> assign_form(changeset)}
  end

  @impl true
  def handle_event("toggle_active", %{"id" => id}, socket) do
    instruction = Enum.find(socket.assigns.instructions, &(&1.id == id))

    case AI.update_instruction(instruction, %{is_active: !instruction.is_active}) do
      {:ok, _} ->
        instructions = AI.list_instructions(socket.assigns.current_user)
        {:noreply, assign(socket, :instructions, instructions)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update instruction")}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    instruction = Enum.find(socket.assigns.instructions, &(&1.id == id))

    case AI.deactivate_instruction(instruction) do
      {:ok, _} ->
        instructions = AI.list_instructions(socket.assigns.current_user)

        {:noreply,
          socket
          |> assign(:instructions, instructions)
          |> put_flash(:info, "Instruction deleted successfully")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete instruction")}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end

  defp new_instruction_changeset do
    %Instruction{}
    |> Instruction.changeset(%{
      instruction_type: "ongoing",
      trigger_type: "manual"
    })
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-4xl">
      <.header>
        AI Agent Instructions
        <:subtitle>
          Set up ongoing instructions for your AI agent to follow automatically.
        </:subtitle>
        <:actions>
          <button
            phx-click="show_new_form"
            class="rounded-md bg-brand px-3 py-2 text-sm font-semibold text-white shadow-sm hover:bg-brand/90"
          >
            <span class="flex items-center gap-2">
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4"></path>
              </svg>
              Add Instruction
            </span>
          </button>
        </:actions>
      </.header>

      <!-- Instruction Form -->
      <div :if={@show_form} class="mt-8 bg-white shadow sm:rounded-lg">
        <div class="px-4 py-5 sm:p-6">
          <h3 class="text-lg font-medium leading-6 text-gray-900">
            <%= if @form_mode == :new, do: "New Instruction", else: "Edit Instruction" %>
          </h3>

          <.form for={@form} phx-change="validate" phx-submit="save" class="mt-5 space-y-4">
            <div>
              <label class="block text-sm font-medium text-gray-700">
                Instruction Type
              </label>
              <select
                name="instruction[instruction_type]"
                class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-brand focus:ring-brand sm:text-sm"
              >
                <option value="ongoing">Ongoing</option>
                <option value="temporary">Temporary</option>
              </select>
            </div>

            <div>
              <label class="block text-sm font-medium text-gray-700">
                Trigger
              </label>
              <select
                name="instruction[trigger_type]"
                class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-brand focus:ring-brand sm:text-sm"
              >
                <option value="manual">Manual</option>
                <option value="email_received">When email is received</option>
                <option value="calendar_event_created">When calendar event is created</option>
                <option value="hubspot_contact_created">When HubSpot contact is created</option>
                <option value="hubspot_contact_updated">When HubSpot contact is updated</option>
              </select>
            </div>

            <div>
              <label class="block text-sm font-medium text-gray-700">
                Instruction
              </label>
              <textarea
                name="instruction[instruction]"
                rows="3"
                class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-brand focus:ring-brand sm:text-sm"
                placeholder="e.g., When someone emails me that is not in HubSpot, create a contact in HubSpot with a note about the email"
              ><%= Phoenix.HTML.Form.input_value(@form, :instruction) %></textarea>
              <.error :for={error <- @form[:instruction].errors}>
                {error}
              </.error>
            </div>

            <div :if={Phoenix.HTML.Form.input_value(@form, :instruction_type) == "temporary"}>
              <label class="block text-sm font-medium text-gray-700">
                Expires At
              </label>
              <input
                type="datetime-local"
                name="instruction[expires_at]"
                value={Phoenix.HTML.Form.input_value(@form, :expires_at)}
                class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-brand focus:ring-brand sm:text-sm"
              />
            </div>

            <div class="pt-5">
              <div class="flex justify-end gap-3">
                <button
                  type="button"
                  phx-click="cancel_form"
                  class="rounded-md bg-white px-3 py-2 text-sm font-semibold text-gray-900 shadow-sm ring-1 ring-inset ring-gray-300 hover:bg-gray-50"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  class="rounded-md bg-brand px-3 py-2 text-sm font-semibold text-white shadow-sm hover:bg-brand/90"
                >
                  <%= if @form_mode == :new, do: "Create", else: "Update" %>
                </button>
              </div>
            </div>
          </.form>
        </div>
      </div>

      <!-- Instructions List -->
      <div class="mt-8 bg-white shadow overflow-hidden sm:rounded-lg">
        <ul class="divide-y divide-gray-200">
          <%= for instruction <- @instructions do %>
            <li class="px-4 py-4 sm:px-6">
              <div class="flex items-start justify-between">
                <div class="flex-1">
                  <div class="flex items-center">
                    <span class={"inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium " <> if(instruction.is_active, do: "bg-green-100 text-green-800", else: "bg-gray-100 text-gray-800")}>
                      <%= if instruction.is_active, do: "Active", else: "Inactive" %>
                    </span>
                    <span class="ml-2 inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-blue-100 text-blue-800">
                      <%= humanize_trigger_type(instruction.trigger_type) %>
                    </span>
                    <%= if instruction.instruction_type == "temporary" do %>
                      <span class="ml-2 inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-yellow-100 text-yellow-800">
                        Temporary
                      </span>
                    <% end %>
                  </div>
                  <p class="mt-2 text-sm text-gray-900">
                    <%= instruction.instruction %>
                  </p>
                  <p class="mt-1 text-xs text-gray-500">
                    Created <%= Calendar.strftime(instruction.inserted_at, "%b %d, %Y at %I:%M %P") %>
                    <%= if instruction.expires_at do %>
                      • Expires <%= Calendar.strftime(instruction.expires_at, "%b %d, %Y at %I:%M %P") %>
                    <% end %>
                  </p>
                </div>
                <div class="ml-4 flex items-center space-x-2">
                  <button
                    phx-click="toggle_active"
                    phx-value-id={instruction.id}
                    class="text-sm text-gray-600 hover:text-gray-900"
                  >
                    <%= if instruction.is_active, do: "Deactivate", else: "Activate" %>
                  </button>
                  <button
                    phx-click="edit"
                    phx-value-id={instruction.id}
                    class="text-sm text-brand hover:text-brand/80"
                  >
                    Edit
                  </button>
                  <button
                    phx-click="delete"
                    phx-value-id={instruction.id}
                    data-confirm="Are you sure you want to delete this instruction?"
                    class="text-sm text-red-600 hover:text-red-900"
                  >
                    Delete
                  </button>
                </div>
              </div>
            </li>
          <% end %>

          <%= if @instructions == [] do %>
            <li class="px-4 py-12 sm:px-6 text-center">
              <p class="text-gray-500">
                No instructions yet. Add one to get started!
              </p>
            </li>
          <% end %>
        </ul>
      </div>
    </div>
    """
  end

  defp humanize_trigger_type("email_received"), do: "Email Received"
  defp humanize_trigger_type("calendar_event_created"), do: "Calendar Event Created"
  defp humanize_trigger_type("hubspot_contact_created"), do: "HubSpot Contact Created"
  defp humanize_trigger_type("hubspot_contact_updated"), do: "HubSpot Contact Updated"
  defp humanize_trigger_type("manual"), do: "Manual"
  defp humanize_trigger_type(_), do: "Unknown"
end
