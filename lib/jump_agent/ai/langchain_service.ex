defmodule JumpAgent.AI.LangchainService do
  @moduledoc """
  Main AI service using Langchain for LLM interactions, embeddings, and tool execution.
  """

  alias LangChain.ChatModels.ChatOpenAI
  alias LangChain.Message
  alias LangChain.Function
  alias LangChain.Chains.LLMChain
  alias LangChain.VectorStores.Ecto
  alias JumpAgent.AI.VectorSearch
  alias JumpAgent.Accounts.User
  require Logger

  @model "gpt-4-turbo"
  @temperature 0.7
  @max_tokens 1000

  @system_prompt """
  You are an intelligent assistant for financial advisors and communications.
  You have access to the user's Gmail, Google Calendar, and HubSpot CRM.

  Your capabilities include:
  - Searching through emails and CRM data to answer questions
  - Scheduling meetings and managing calendar events
  - Sending emails on behalf of the user
  - Creating and updating contacts in HubSpot
  - Adding notes to HubSpot contacts
  - Following ongoing instructions set by the user

  Always be helpful, concise, and proactive. When executing tasks, provide clear updates
  on what you're doing. If you need more information to complete a task, ask for it.
  """

  @doc """
  Creates a new ChatOpenAI model instance
  """
  def create_chat_model(opts \\ []) do
    api_key = Application.get_env(:openai_ex, :api_key) ||
      Application.get_env(:langchain, :openai_api_key)

    if is_nil(api_key) || api_key == "" do
      {:error, :no_api_key}
    else
      model = Keyword.get(opts, :model, @model)
      temperature = Keyword.get(opts, :temperature, @temperature)

      ChatOpenAI.new!(%{
        api_key: api_key,
        model: model,
        temperature: temperature,
        stream: Keyword.get(opts, :stream, false),
        max_tokens: Keyword.get(opts, :max_tokens, @max_tokens)
      })
    end
  end

  @doc """
  Creates an LLM chain for conversation
  """
  def create_conversation_chain(opts \\ []) do
    case create_chat_model(opts) do
      {:error, reason} -> {:error, reason}
      chat_model ->
        {:ok, LLMChain.new!(%{
          llm: chat_model,
          verbose: false
        })}
    end
  end

  @doc """
  Processes a message with tools/functions available
  """
  def process_message_with_tools(messages, functions, opts \\ []) do
    case create_chat_model(opts) do
      {:error, reason} ->
        {:error, reason}

      chat_model ->
        # Add system message if not present
        messages = ensure_system_message(messages)

        # Run the chain with functions
        try do
          result = LLMChain.run(chat_model,
            messages: messages,
            functions: functions,
            function_call: "auto"
          )

          {:ok, result}
        rescue
          e ->
            Logger.error("Langchain error: #{inspect(e)}")
            {:error, :langchain_error}
        end
    end
  end

  @doc """
  Generates embeddings for text
  """
  def generate_embedding(text) when is_binary(text) do
    api_key = Application.get_env(:openai_ex, :api_key) ||
      Application.get_env(:langchain, :openai_api_key)

    if is_nil(api_key) || api_key == "" do
      {:error, :no_api_key}
    else
      # Make direct API request to OpenAI using Finch
      try do
        headers = [
          {"Authorization", "Bearer #{api_key}"},
          {"Content-Type", "application/json"}
        ]
        
        body = Jason.encode!(%{
          model: "text-embedding-3-small",
          input: text
        })

        case Finch.build(:post, "https://api.openai.com/v1/embeddings", headers, body)
             |> Finch.request(JumpAgent.Finch, receive_timeout: 30_000) do
          {:ok, %Finch.Response{status: 200, body: response_body}} ->
            parsed_body = Jason.decode!(response_body)
            embedding = parsed_body["data"] |> List.first() |> Map.get("embedding")
            {:ok, embedding}

          {:ok, %Finch.Response{status: status, body: response_body}} ->
            Logger.error("OpenAI API error (#{status}): #{response_body}")
            {:error, :api_error}

          {:error, error} ->
            Logger.error("OpenAI request failed: #{inspect(error)}")
            {:error, :request_error}
        end
      rescue
        error ->
          Logger.error("OpenAI embedding error: #{inspect(error)}")
          {:error, :embedding_error}
      end
    end
  end

  @doc """
  Creates Langchain Function definitions for our tools
  """
  def get_tool_functions do
    [
      search_information_function(),
      send_email_function(),
      schedule_meeting_function(),
      create_calendar_event_function(),
      create_contact_function(),
      update_contact_function(),
      add_hubspot_note_function()
    ]
  end

  # Tool function definitions

  defp search_information_function do
    Function.new!(%{
      name: "search_information",
      description: "Search through emails, contacts, and calendar events to find information",
      parameters_schema: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "The search query"
          },
          source_types: %{
            type: "array",
            items: %{
              type: "string",
              enum: ["gmail", "hubspot_contact", "hubspot_note", "calendar"]
            },
            description: "Types of sources to search (optional, searches all if not specified)"
          }
        },
        required: ["query"]
      },
      function: fn args, context ->
        # The function execution logic will be handled by the LangchainFunctionExecutor
        {:ok, "Function call will be handled by executor"}
      end
    })
  end

  defp send_email_function do
    Function.new!(%{
      name: "send_email",
      description: "Send an email on behalf of the user",
      parameters_schema: %{
        type: "object",
        properties: %{
          to: %{
            type: "string",
            description: "Recipient email address"
          },
          subject: %{
            type: "string",
            description: "Email subject"
          },
          body: %{
            type: "string",
            description: "Email body (plain text or HTML)"
          },
          cc: %{
            type: "array",
            items: %{type: "string"},
            description: "CC recipients (optional)"
          },
          bcc: %{
            type: "array",
            items: %{type: "string"},
            description: "BCC recipients (optional)"
          }
        },
        required: ["to", "subject", "body"]
      },
      function: fn args, context ->
        {:ok, "Function call will be handled by executor"}
      end
    })
  end

  defp schedule_meeting_function do
    Function.new!(%{
      name: "schedule_meeting",
      description: "Schedule a meeting by sending available times and handling responses",
      parameters_schema: %{
        type: "object",
        properties: %{
          contact_email: %{
            type: "string",
            description: "Email of the person to schedule with"
          },
          meeting_title: %{
            type: "string",
            description: "Title/purpose of the meeting"
          },
          duration_minutes: %{
            type: "integer",
            description: "Duration of the meeting in minutes",
            default: 30
          },
          preferred_times: %{
            type: "array",
            items: %{
              type: "object",
              properties: %{
                date: %{type: "string", description: "Date in YYYY-MM-DD format"},
                time: %{type: "string", description: "Time in HH:MM format (24-hour)"}
              }
            },
            description: "List of preferred meeting times"
          },
          message: %{
            type: "string",
            description: "Additional message to include"
          }
        },
        required: ["contact_email", "meeting_title"]
      },
      function: fn args, context ->
        {:ok, "Function call will be handled by executor"}
      end
    })
  end

  defp create_calendar_event_function do
    Function.new!(%{
      name: "create_calendar_event",
      description: "Create an event in the user's Google Calendar",
      parameters_schema: %{
        type: "object",
        properties: %{
          title: %{
            type: "string",
            description: "Event title"
          },
          start_time: %{
            type: "string",
            description: "Start time in ISO 8601 format"
          },
          end_time: %{
            type: "string",
            description: "End time in ISO 8601 format"
          },
          description: %{
            type: "string",
            description: "Event description (optional)"
          },
          location: %{
            type: "string",
            description: "Event location (optional)"
          },
          attendees: %{
            type: "array",
            items: %{type: "string"},
            description: "List of attendee email addresses (optional)"
          }
        },
        required: ["title", "start_time", "end_time"]
      },
      function: fn args, context ->
        {:ok, "Function call will be handled by executor"}
      end
    })
  end

  defp create_contact_function do
    Function.new!(%{
      name: "create_contact",
      description: "Create a new contact in HubSpot CRM",
      parameters_schema: %{
        type: "object",
        properties: %{
          email: %{
            type: "string",
            description: "Contact email address"
          },
          first_name: %{
            type: "string",
            description: "Contact first name"
          },
          last_name: %{
            type: "string",
            description: "Contact last name"
          },
          company: %{
            type: "string",
            description: "Contact company (optional)"
          },
          phone: %{
            type: "string",
            description: "Contact phone number (optional)"
          },
          notes: %{
            type: "string",
            description: "Initial notes about the contact (optional)"
          }
        },
        required: ["email"]
      },
      function: fn args, context ->
        {:ok, "Function call will be handled by executor"}
      end
    })
  end

  defp update_contact_function do
    Function.new!(%{
      name: "update_contact",
      description: "Update an existing contact in HubSpot CRM",
      parameters_schema: %{
        type: "object",
        properties: %{
          email: %{
            type: "string",
            description: "Email to identify the contact"
          },
          properties: %{
            type: "object",
            description: "Properties to update",
            additionalProperties: true
          }
        },
        required: ["email", "properties"]
      },
      function: fn args, context ->
        {:ok, "Function call will be handled by executor"}
      end
    })
  end

  defp add_hubspot_note_function do
    Function.new!(%{
      name: "add_hubspot_note",
      description: "Add a note to a HubSpot contact",
      parameters_schema: %{
        type: "object",
        properties: %{
          contact_email: %{
            type: "string",
            description: "Email of the contact to add note to"
          },
          note_content: %{
            type: "string",
            description: "Content of the note"
          }
        },
        required: ["contact_email", "note_content"]
      },
      function: fn args, context ->
        {:ok, "Function call will be handled by executor"}
      end
    })
  end

  defp ensure_system_message(messages) do
    has_system = Enum.any?(messages, fn msg ->
      (is_map(msg) && msg.role == "system") ||
        (is_struct(msg) && msg.__struct__ == Message && msg.role == :system)
    end)

    if has_system do
      messages
    else
      [Message.new_system(@system_prompt) | messages]
    end
  end

  @doc """
  Converts messages to Langchain Message format
  """
  def to_langchain_messages(messages) when is_list(messages) do
    Enum.map(messages, &to_langchain_message/1)
  end

  defp to_langchain_message(%{role: "system", content: content}) do
    Message.new_system(content)
  end
  defp to_langchain_message(%{role: "user", content: content}) do
    Message.new_user(content)
  end
  defp to_langchain_message(%{role: "assistant", content: content}) do
    Message.new_assistant(content)
  end
  defp to_langchain_message(%{"role" => role, "content" => content}) do
    to_langchain_message(%{role: role, content: content})
  end
  defp to_langchain_message(msg), do: msg
end
