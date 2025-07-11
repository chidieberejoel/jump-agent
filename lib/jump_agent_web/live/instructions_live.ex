defmodule JumpAgentWeb.InstructionsLive do
  use JumpAgentWeb, :live_view

  alias JumpAgent.AI
  alias JumpAgent.AI.Instruction
  alias JumpAgent.Repo

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if connected?(socket) do
      instructions = AI.list_instructions(user)

      {:ok,
        socket
        |> assign(:instructions, instructions)
        |> assign(:show_form, false)
        |> assign(:form_mode, :new)
        |> assign(:editing_instruction, nil)
        |> assign_form(new_instruction_changeset(user.id))}
    else
      {:ok,
        socket
        |> assign(:instructions, [])
        |> assign(:show_form, false)
        |> assign(:form_mode, :new)
        |> assign(:editing_instruction, nil)
        |> assign_form(new_instruction_changeset(user.id))}
    end
  end

  @impl true
  def handle_event("show_new_form", _params, socket) do
    {:noreply,
      socket
      |> assign(:show_form, true)
      |> assign(:form_mode, :new)
      |> assign(:editing_instruction, nil)
      |> assign_form(new_instruction_changeset(socket.assigns.current_user.id))}
  end

  @impl true
  def handle_event("cancel_form", _params, socket) do
    {:noreply,
      socket
      |> assign(:show_form, false)
      |> assign(:form_mode, :new)
      |> assign(:editing_instruction, nil)
      |> assign_form(new_instruction_changeset(socket.assigns.current_user.id))}
  end

  @impl true
  def handle_event("validate", %{"instruction" => params}, socket) do
    params = Map.put(params, "user_id", socket.assigns.current_user.id)

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

    # Store the form mode before potentially updating it
    action = socket.assigns.form_mode

    result =
      if action == :new do
        %Instruction{}
        |> Instruction.changeset(params)
        |> Repo.insert()
      else
        socket.assigns.editing_instruction
        |> Instruction.changeset(params)
        |> Repo.update()
      end

    case result do
      {:ok, _instruction} ->
        instructions = AI.list_instructions(user)

        {:noreply,
          socket
          |> assign(:instructions, instructions)
          |> assign(:show_form, false)
          |> assign(:form_mode, :new)
          |> assign(:editing_instruction, nil)
          |> assign_form(new_instruction_changeset(user.id))
          |> put_flash(:info, "Instruction #{if action == :new, do: "created", else: "updated"} successfully!")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    instruction = Enum.find(socket.assigns.instructions, &(&1.id == id))

    if instruction do
      # Create changeset with the instruction's current data
      changeset = Instruction.changeset(instruction, %{})

      {:noreply,
        socket
        |> assign(:show_form, true)
        |> assign(:form_mode, :edit)
        |> assign(:editing_instruction, instruction)
        |> assign_form(changeset)}
    else
      {:noreply, socket}
    end
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

  defp new_instruction_changeset(user_id) do
    attrs = %{
      "user_id" => user_id,
      "instruction_type" => "ongoing",
      "trigger_type" => "manual",
      "instruction" => ""
    }

    %Instruction{}
    |> Instruction.changeset(attrs)
  end

  defp humanize_trigger_type(type) do
    case type do
      "email_received" -> "Email Received"
      "calendar_event_created" -> "Calendar Event Created"
      "hubspot_contact_created" -> "HubSpot Contact Created"
      "hubspot_contact_updated" -> "HubSpot Contact Updated"
      "manual" -> "Manual"
      "scheduled" -> "Scheduled"
      nil -> "Manual"
      _ -> String.replace(type || "", "_", " ") |> String.split() |> Enum.map(&String.capitalize/1) |> Enum.join(" ")
    end
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
              <.input
                field={@form[:instruction_type]}
                type="select"
                label="Instruction Type"
                options={[{"Ongoing", "ongoing"}, {"Temporary", "temporary"}]}
              />
            </div>

            <div>
              <.input
                field={@form[:trigger_type]}
                type="select"
                label="Trigger Type"
                options={[
                  {"Manual", "manual"},
                  {"When Email Received", "email_received"},
                  {"When Calendar Event Created", "calendar_event_created"},
                  {"When HubSpot Contact Created", "hubspot_contact_created"},
                  {"When HubSpot Contact Updated", "hubspot_contact_updated"},
                  {"Scheduled", "scheduled"}
                ]}
              />
            </div>

            <div>
              <.input
                field={@form[:instruction]}
                type="textarea"
                label="Instruction"
                rows="4"
                placeholder="e.g., When I receive an email from a new contact, create them in my CRM..."
              />
            </div>

            <div :if={Phoenix.HTML.Form.input_value(@form, :instruction_type) == "temporary"}>
              <.input
                field={@form[:expires_at]}
                type="datetime-local"
                label="Expires At"
              />
            </div>

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
          </.form>
        </div>
      </div>

      <!-- Instructions List -->
      <div class="mt-8">
        <div :if={Enum.empty?(@instructions)} class="bg-white shadow sm:rounded-lg p-12 text-center">
          <svg class="mx-auto h-12 w-12 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"></path>
          </svg>
          <h3 class="mt-2 text-sm font-medium text-gray-900">No instructions</h3>
          <p class="mt-1 text-sm text-gray-500">Get started by creating a new instruction.</p>
        </div>

        <ul :if={!Enum.empty?(@instructions)} class="divide-y divide-gray-200 bg-white shadow sm:rounded-lg">
          <li :for={instruction <- @instructions} class="px-4 py-4 sm:px-6">
            <div class="flex items-start justify-between">
              <div class="flex-1">
                <div class="flex items-center mb-2">
                  <span class={"inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium " <> if(instruction.is_active, do: "bg-green-100 text-green-800", else: "bg-gray-100 text-gray-800")}>
                    <%= if instruction.is_active, do: "Active", else: "Inactive" %>
                  </span>
                  <span class="ml-2 inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-blue-100 text-blue-800">
                    <%= humanize_trigger_type(instruction.trigger_type) %>
                  </span>
                  <span class="ml-2 inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-purple-100 text-purple-800">
                    <%= String.capitalize(instruction.instruction_type) %>
                  </span>
                </div>
                <p class="text-sm text-gray-900"><%= instruction.instruction %></p>
                <p class="mt-1 text-xs text-gray-500">
                  Created <%= Calendar.strftime(instruction.inserted_at, "%B %d, %Y at %I:%M %p") %>
                </p>
              </div>
              <div class="ml-4 flex items-center space-x-2">
                <button
                  phx-click="toggle_active"
                  phx-value-id={instruction.id}
                  class="text-gray-400 hover:text-gray-500"
                  title={if instruction.is_active, do: "Deactivate", else: "Activate"}
                >
                  <%= if instruction.is_active do %>
                    <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 9v6m4-6v6m7-3a9 9 0 11-18 0 9 9 0 0118 0z"></path>
                    </svg>
                  <% else %>
                    <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z"></path>
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
                    </svg>
                  <% end %>
                </button>
                <button
                  phx-click="edit"
                  phx-value-id={instruction.id}
                  class="text-gray-400 hover:text-gray-500"
                  title="Edit"
                >
                  <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"></path>
                  </svg>
                </button>
                <button
                  phx-click="delete"
                  phx-value-id={instruction.id}
                  data-confirm="Are you sure you want to delete this instruction?"
                  class="text-gray-400 hover:text-red-500"
                  title="Delete"
                >
                  <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"></path>
                  </svg>
                </button>
              </div>
            </div>
          </li>
        </ul>
      </div>
    </div>
    """
  end
end
