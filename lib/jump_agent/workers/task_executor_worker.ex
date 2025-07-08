defmodule JumpAgent.Workers.TaskExecutorWorker do
  @moduledoc """
  Executes AI tasks using the appropriate tools.
  """

  use Oban.Worker, queue: :ai, max_attempts: 3

  alias JumpAgent.AI
  alias JumpAgent.AI.{Task, ToolExecutor}
  alias JumpAgent.Accounts
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => task_id}}) do
    task = AI.get_task!(task_id)
    user = Accounts.get_user!(task.user_id)

    # Update task status
    {:ok, task} = AI.update_task(task, %{
      status: "in_progress",
      attempts: task.attempts + 1
    })

    # Execute the tool
    result = ToolExecutor.execute(task.type, user, task.parameters)

    case result do
      {:ok, response} ->
        handle_success(task, response)
      {:waiting, context} ->
        handle_waiting(task, context)
      {:error, reason} ->
        handle_error(task, reason)
    end
  end

  defp handle_success(task, response) do
    {:ok, _} = AI.update_task(task, %{
      status: "completed",
      result: response,
      completed_at: DateTime.utc_now()
    })

    # If there's a conversation, add a tool response message
    if task.conversation_id do
      conversation = AI.get_conversation!(Accounts.get_user!(task.user_id), task.conversation_id)

      AI.create_message(conversation, %{
        role: "tool",
        content: format_tool_response(task.type, response),
        tool_call_id: task.id
      })
    end

    :ok
  end

  defp handle_waiting(task, context) do
    {:ok, _} = AI.update_task(task, %{
      status: "waiting",
      context: Map.merge(task.context, context)
    })

    # Schedule a check based on the wait type
    wait_minutes = Map.get(context, "wait_minutes", 60)

    %{task_id: task.id}
    |> new(schedule_in: wait_minutes * 60)
    |> Oban.insert()

    :ok
  end

  defp handle_error(task, reason) do
    error_message = format_error(reason)

    if task.attempts >= 3 do
      # Mark as failed after max attempts
      {:ok, _} = AI.update_task(task, %{
        status: "failed",
        error: error_message,
        completed_at: DateTime.utc_now()
      })
    else
      # Update error and retry
      {:ok, _} = AI.update_task(task, %{
        status: "pending",
        error: error_message
      })

      # Exponential backoff
      retry_in = :math.pow(2, task.attempts) * 60

      %{task_id: task.id}
      |> new(schedule_in: round(retry_in))
      |> Oban.insert()
    end

    :ok
  end

  defp format_tool_response("send_email", %{"message_id" => id}), do: "Email sent successfully (ID: #{id})"
  defp format_tool_response("create_contact", %{"contact_id" => id}), do: "Contact created successfully (ID: #{id})"
  defp format_tool_response("create_calendar_event", %{"event_id" => id}), do: "Calendar event created (ID: #{id})"
  defp format_tool_response(tool, response), do: "#{tool} completed: #{inspect(response)}"

  defp format_error({:api_error, message}), do: "API Error: #{message}"
  defp format_error({:validation_error, errors}), do: "Validation Error: #{inspect(errors)}"
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: "Unknown error: #{inspect(error)}"
end
