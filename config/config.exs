# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :jump_agent,
  ecto_repos: [JumpAgent.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Configures the endpoint
config :jump_agent, JumpAgentWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: JumpAgentWeb.ErrorHTML, json: JumpAgentWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: JumpAgent.PubSub,
  live_view: [signing_salt: "aou77Qqc"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :jump_agent, JumpAgent.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  jump_agent: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.3",
  jump_agent: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure Ueberauth
config :ueberauth, Ueberauth,
  providers: [
   google: {Ueberauth.Strategy.Google, [
     default_scope: "email profile https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/calendar",
     access_type: "offline",
     prompt: "consent"
   ]}
  ]

# Configure Oban
config :jump_agent, Oban,
  repo: JumpAgent.Repo,
  plugins: [
   Oban.Plugins.Pruner,
   {Oban.Plugins.Cron, crontab: [
     # Sync Gmail every 5 minutes
     {"*/5 * * * *", JumpAgent.Workers.GmailSyncWorker},
     # Sync HubSpot every 10 minutes
     {"*/10 * * * *", JumpAgent.Workers.HubSpotSyncWorker},
     # Process pending tasks every minute
     {"* * * * *", JumpAgent.Workers.TaskProcessorWorker},
     # Webhook maintenance every 6 hours
     {"0 */6 * * *", JumpAgent.Workers.WebhookMaintenanceWorker},
     # Embedding maintenance every hour
     {"0 * * * *", JumpAgent.Workers.EmbeddingMaintenanceWorker}
   ]}
  ],
  queues: [default: 10, sync: 5, ai: 3, webhooks: 5, maintenance: 3, embeddings: 5]

config :jump_agent, JumpAgent.Repo, types: JumpAgent.PostgrexTypes

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
