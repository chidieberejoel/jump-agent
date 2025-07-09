defmodule JumpAgent.ConfigHelper do
  @moduledoc """
  Helper module to check configuration and diagnose issues.
  """

  def check_all do
    IO.puts("\n=== JumpAgent Configuration Check ===\n")

    check_langchain()
    check_google()
    check_hubspot()
    check_database()
    check_processes()

    IO.puts("\n=== End of Configuration Check ===\n")
  end

  def check_langchain do
    IO.puts("📋 Langchain/OpenAI Configuration:")

    api_key = Application.get_env(:langchain, :openai_api_key)

    if is_nil(api_key) || api_key == "" do
      IO.puts("  ❌ API Key: NOT SET")
      IO.puts("     Set OPENAI_API_KEY environment variable")
    else
      masked_key = String.slice(api_key, 0, 7) <> "..." <> String.slice(api_key, -4, 4)
      IO.puts("  ✅ API Key: #{masked_key}")
    end

    # Check if Langchain is properly configured
    try do
      LangChain.ChatModels.ChatOpenAI.new!(%{api_key: api_key || "test", model: "gpt-4"})
      IO.puts("  ✅ Langchain: Configured")
    rescue
      _ ->
        IO.puts("  ❌ Langchain: Configuration Error")
    end

    IO.puts("")
  end

  def check_google do
    IO.puts("📋 Google OAuth Configuration:")

    client_id = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)[:client_id]
    client_secret = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)[:client_secret]

    if client_id do
      IO.puts("  ✅ Client ID: Configured")
    else
      IO.puts("  ❌ Client ID: NOT SET")
    end

    if client_secret do
      IO.puts("  ✅ Client Secret: Configured")
    else
      IO.puts("  ❌ Client Secret: NOT SET")
    end

    IO.puts("")
  end

  def check_hubspot do
    IO.puts("📋 HubSpot Configuration:")

    client_id = Application.get_env(:jump_agent, :hubspot_client_id)
    client_secret = Application.get_env(:jump_agent, :hubspot_client_secret)

    if client_id do
      IO.puts("  ✅ Client ID: Configured")
    else
      IO.puts("  ❌ Client ID: NOT SET")
    end

    if client_secret do
      IO.puts("  ✅ Client Secret: Configured")
    else
      IO.puts("  ❌ Client Secret: NOT SET")
    end

    IO.puts("")
  end

  def check_database do
    IO.puts("📋 Database Connection:")

    try do
      Ecto.Adapters.SQL.query!(JumpAgent.Repo, "SELECT 1", [])
      IO.puts("  ✅ Connection: Working")

      # Check if pgvector is installed
      case Ecto.Adapters.SQL.query(JumpAgent.Repo, "SELECT extname FROM pg_extension WHERE extname = 'vector'", []) do
        {:ok, %{rows: [["vector"]]}} ->
          IO.puts("  ✅ pgvector: Installed")
        _ ->
          IO.puts("  ⚠️  pgvector: Not installed (embeddings won't work)")
      end
    rescue
      _ ->
        IO.puts("  ❌ Connection: Failed")
    end

    IO.puts("")
  end

  def check_processes do
    IO.puts("📋 Application Processes:")

    processes = [
      {JumpAgent.AI.Metrics, "AI Metrics"},
      {Oban, "Background Jobs"},
      {JumpAgent.Finch, "HTTP Client"}
    ]

    Enum.each(processes, fn {module, name} ->
      if Process.whereis(module) do
        IO.puts("  ✅ #{name}: Running")
      else
        IO.puts("  ❌ #{name}: Not Running")
      end
    end)

    IO.puts("")
  end
end
