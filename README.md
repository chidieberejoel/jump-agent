# JumpAgent

An AI-powered assistant for financial advisors that seamlessly integrates with Gmail, Google Calendar, and HubSpot CRM to help manage contacts, schedule meetings, and maintain meaningful professional connections through natural conversation.

## Features

- **AI Chat Assistant**: Natural language interface powered by OpenAI GPT-4
- **Email Management**: Search, read, and send emails through Gmail integration
- **Calendar Integration**: Schedule meetings and manage calendar events
- **CRM Integration**: Sync contacts and notes with HubSpot automatically
- **Smart Search**: Vector similarity search across all your data using embeddings
- **Automated Workflows**: Set up instructions that trigger on specific events
- **Real-time Updates**: Live dashboard with Phoenix LiveView
- **Background Processing**: Efficient task execution with job queues

## Technology Stack

- **Backend**: Elixir with Phoenix Framework
- **Database**: PostgreSQL with pgvector extension
- **AI**: OpenAI GPT-4 API
- **Frontend**: Phoenix LiveView, Tailwind CSS
- **Authentication**: OAuth 2.0 (Google, HubSpot)
- **Background Jobs**: Oban
- **HTTP Client**: Finch

## Prerequisites

- Elixir 1.14+
- PostgreSQL 14+ with pgvector extension
- Node.js 16+ (for assets)
- Google Cloud Console account (for OAuth)
- HubSpot developer account
- OpenAI API key

## Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/yourusername/jump_agent.git
   cd jump_agent
   ```

2. **Install dependencies**
   ```bash
   mix deps.get
   mix deps.compile
   ```

3. **Set up the database**
   ```bash
   # Make sure PostgreSQL is running
   mix ecto.create
   mix ecto.migrate
   ```

## Configuration

1. **Copy the example environment file**
   ```bash
   cp .env.example .env
   ```

2. **Configure your environment variables**

   ### Google OAuth
    - Go to [Google Cloud Console](https://console.cloud.google.com)
    - Create a new project or select existing
    - Enable Gmail API and Google Calendar API
    - Create OAuth 2.0 credentials
    - Add authorized redirect URI: `http://localhost:4000/auth/google/callback`
    - Copy Client ID and Client Secret to `.env`

   ### HubSpot OAuth
    - Go to [HubSpot Developers](https://developers.hubspot.com)
    - Create a new app
    - Set redirect URL: `http://localhost:4000/hubspot/callback`
    - Copy Client ID and Client Secret to `.env`

   ### OpenAI API
    - Get your API key from [OpenAI Platform](https://platform.openai.com)
    - Add to `.env` as `OPENAI_API_KEY`

   ### Token Encryption Key
   ```bash
   # Generate a secure key:
   mix run -e "IO.puts(:crypto.strong_rand_bytes(32) |> Base.encode64())"
   ```

3. **Load environment variables**
   ```bash
   source .env
   ```

## Running the Application

1. **Start the Phoenix server**
   ```bash
   mix phx.server
   ```

2. **Visit the application**
    - Open [http://localhost:4000](http://localhost:4000)
    - Sign in with Google
    - Connect your HubSpot account (optional)
    - Start chatting with your AI assistant!

## Key Concepts

### AI Agent
The AI agent processes natural language requests and can:
- Search through your emails and contacts
- Send emails on your behalf
- Schedule meetings
- Create and update CRM contacts
- Execute automated workflows

### Vector Search
Documents are converted to embeddings and stored in PostgreSQL with pgvector, enabling semantic search across all your data.

### Background Jobs
Long-running tasks are processed asynchronously using Oban:
- Email synchronization
- Contact syncing
- AI task execution

### Real-time Updates
Phoenix LiveView powers the chat interface and dashboard for instant updates without page refreshes.
