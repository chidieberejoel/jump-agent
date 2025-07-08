defmodule JumpAgent.AI.Tools do
  @moduledoc """
  Defines the tools available to the AI agent.
  """

  @doc """
  Returns the list of available tools in OpenAI function format.
  """
  def available_tools do
    [
      search_information_tool(),
      send_email_tool(),
      schedule_meeting_tool(),
      create_calendar_event_tool(),
      create_contact_tool(),
      update_contact_tool(),
      add_hubspot_note_tool()
    ]
  end

  defp search_information_tool do
    %{
      type: "function",
      function: %{
        name: "search_information",
        description: "Search through emails, contacts, and calendar events to find information",
        parameters: %{
          type: "object",
          properties: %{
            query: %{
              type: "string",
              description: "The search query"
            },
            source_types: %{
              type: "array",
              items: %{type: "string", enum: ["gmail", "hubspot_contact", "hubspot_note", "calendar"]},
              description: "Types of sources to search (optional, searches all if not specified)"
            }
          },
          required: ["query"]
        }
      }
    }
  end

  defp send_email_tool do
    %{
      type: "function",
      function: %{
        name: "send_email",
        description: "Send an email on behalf of the user",
        parameters: %{
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
        }
      }
    }
  end

  defp schedule_meeting_tool do
    %{
      type: "function",
      function: %{
        name: "schedule_meeting",
        description: "Schedule a meeting by sending available times and handling responses",
        parameters: %{
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
              description: "List of preferred meeting times (optional, will find available slots if not provided)"
            },
            message: %{
              type: "string",
              description: "Additional message to include in the scheduling email"
            }
          },
          required: ["contact_email", "meeting_title"]
        }
      }
    }
  end

  defp create_calendar_event_tool do
    %{
      type: "function",
      function: %{
        name: "create_calendar_event",
        description: "Create an event in the user's Google Calendar",
        parameters: %{
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
        }
      }
    }
  end

  defp create_contact_tool do
    %{
      type: "function",
      function: %{
        name: "create_contact",
        description: "Create a new contact in HubSpot CRM",
        parameters: %{
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
        }
      }
    }
  end

  defp update_contact_tool do
    %{
      type: "function",
      function: %{
        name: "update_contact",
        description: "Update an existing contact in HubSpot CRM",
        parameters: %{
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
        }
      }
    }
  end

  defp add_hubspot_note_tool do
    %{
      type: "function",
      function: %{
        name: "add_hubspot_note",
        description: "Add a note to a HubSpot contact",
        parameters: %{
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
        }
      }
    }
  end
end
