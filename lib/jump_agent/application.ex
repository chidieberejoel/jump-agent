defmodule JumpAgent.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      JumpAgentWeb.Telemetry,
      JumpAgent.Repo,
      {DNSCluster, query: Application.get_env(:jump_agent, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: JumpAgent.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: JumpAgent.Finch},
      # Start a worker by calling: JumpAgent.Worker.start_link(arg)
      # {JumpAgent.Worker, arg},
      # Start to serve requests, typically the last entry
      JumpAgentWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: JumpAgent.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    JumpAgentWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
