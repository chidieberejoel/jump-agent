defmodule JumpAgentWeb.HealthController do
  use JumpAgentWeb, :controller

  alias JumpAgent.{Repo, AI}

  def check(conn, _params) do
    health_data = %{
      status: "ok",
      timestamp: DateTime.utc_now(),
      checks: perform_checks()
    }

    overall_status =
      if Enum.all?(health_data.checks, fn {_, check} -> check.status == "healthy" end) do
        :ok
      else
        :service_unavailable
      end

    conn
    |> put_status(overall_status)
    |> json(health_data)
  end

  def metrics(conn, _params) do
    # Require authentication for metrics
    if get_req_header(conn, "authorization") == [Application.get_env(:jump_agent, :metrics_token, "metrics_token")] do
      metrics = AI.Metrics.get_stats()

      conn
      |> put_status(:ok)
      |> json(%{
        timestamp: DateTime.utc_now(),
        metrics: metrics
      })
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized"})
    end
  end

  defp perform_checks do
    %{
      database: check_database(),
      langchain: check_langchain(),
      oban: check_oban(),
      ai_system: check_ai_system()
    }
  end

  defp check_database do
    try do
      Ecto.Adapters.SQL.query!(Repo, "SELECT 1", [])
      %{status: "healthy", message: "Database connection OK"}
    rescue
      _ -> %{status: "unhealthy", message: "Database connection failed"}
    end
  end

  defp check_oban do
    try do
      # Check if Oban is running and healthy
      Oban.check_queue(Oban, queue: :default)
      %{status: "healthy", message: "Background jobs running"}
    rescue
      _ -> %{status: "unhealthy", message: "Background job system error"}
    end
  end

  defp check_ai_system do
    case AI.Metrics.get_health_status() do
      :healthy -> %{status: "healthy", message: "AI system operating normally"}
      :degraded -> %{status: "degraded", message: "AI system experiencing elevated errors"}
      :unhealthy -> %{status: "unhealthy", message: "AI system error rate too high"}
    end
  end

  defp check_langchain do
    # Check if Langchain/OpenAI is configured
    api_key = Application.get_env(:langchain, :openai_api_key)

    if api_key && api_key != "" do
      %{status: "healthy", message: "Langchain configured with OpenAI"}
    else
      %{status: "unhealthy", message: "OpenAI API key not configured"}
    end
  end
end
