defmodule JumpAgent.Workers.TaskProcessorWorker do
  @moduledoc """
  Periodically checks for pending AI tasks and queues them for execution.
  """

  use Oban.Worker, queue: :default

  alias JumpAgent.{Accounts, AI}
  require Logger

  @impl Oban.Worker
  def perform(_job) do
    # Get all users
    users = Accounts.list_all_users()

    Enum.each(users, &process_user_tasks/1)

    :ok
  end

  defp process_user_tasks(user) do
    # Get pending tasks for this user
    tasks = AI.get_pending_tasks(user)

    Enum.each(tasks, fn task ->
      # Queue each task for execution
      %{task_id: task.id}
      |> JumpAgent.Workers.TaskExecutorWorker.new()
      |> Oban.insert()
    end)
  end
end
