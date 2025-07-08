defmodule JumpAgent.AI.ToolValidator do
  @moduledoc """
  Validates parameters for AI tool execution.
  """

  @email_regex ~r/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}$/

  def validate("send_email", params) do
    with :ok <- validate_required(params, ["to", "subject", "body"]),
         :ok <- validate_email(params["to"]),
         :ok <- validate_string(params["subject"], min: 1, max: 200),
         :ok <- validate_string(params["body"], min: 1, max: 10000),
         :ok <- validate_email_list(params["cc"]),
         :ok <- validate_email_list(params["bcc"]) do
      {:ok, params}
    end
  end

  def validate("schedule_meeting", params) do
    with :ok <- validate_required(params, ["contact_email", "meeting_title"]),
         :ok <- validate_email(params["contact_email"]),
         :ok <- validate_string(params["meeting_title"], min: 1, max: 200),
         :ok <- validate_integer(params["duration_minutes"], min: 15, max: 480, default: 30),
         :ok <- validate_meeting_times(params["preferred_times"]) do
      {:ok, params}
    end
  end

  def validate("create_calendar_event", params) do
    with :ok <- validate_required(params, ["title", "start_time", "end_time"]),
         :ok <- validate_string(params["title"], min: 1, max: 200),
         :ok <- validate_datetime(params["start_time"]),
         :ok <- validate_datetime(params["end_time"]),
         :ok <- validate_datetime_order(params["start_time"], params["end_time"]),
         :ok <- validate_string(params["description"], max: 5000),
         :ok <- validate_string(params["location"], max: 500),
         :ok <- validate_email_list(params["attendees"]) do
      {:ok, params}
    end
  end

  def validate("create_contact", params) do
    with :ok <- validate_required(params, ["email"]),
         :ok <- validate_email(params["email"]),
         :ok <- validate_string(params["first_name"], max: 100),
         :ok <- validate_string(params["last_name"], max: 100),
         :ok <- validate_string(params["company"], max: 200),
         :ok <- validate_phone(params["phone"]),
         :ok <- validate_string(params["notes"], max: 5000) do
      {:ok, params}
    end
  end

  def validate("update_contact", params) do
    with :ok <- validate_required(params, ["email", "properties"]),
         :ok <- validate_email(params["email"]),
         :ok <- validate_map(params["properties"]) do
      {:ok, params}
    end
  end

  def validate("add_hubspot_note", params) do
    with :ok <- validate_required(params, ["contact_email", "note_content"]),
         :ok <- validate_email(params["contact_email"]),
         :ok <- validate_string(params["note_content"], min: 1, max: 5000) do
      {:ok, params}
    end
  end

  def validate("search_information", params) do
    with :ok <- validate_required(params, ["query"]),
         :ok <- validate_string(params["query"], min: 1, max: 500),
         :ok <- validate_source_types(params["source_types"]) do
      {:ok, params}
    end
  end

  def validate(_tool, params), do: {:ok, params}

  # Validation helpers

  defp validate_required(params, required_fields) do
    missing = Enum.filter(required_fields, fn field ->
      is_nil(params[field]) || params[field] == ""
    end)

    if missing == [] do
      :ok
    else
      {:error, "Missing required fields: #{Enum.join(missing, ", ")}"}
    end
  end

  defp validate_email(nil), do: :ok
  defp validate_email(email) when is_binary(email) do
    if Regex.match?(@email_regex, email) do
      :ok
    else
      {:error, "Invalid email format: #{email}"}
    end
  end
  defp validate_email(_), do: {:error, "Email must be a string"}

  defp validate_email_list(nil), do: :ok
  defp validate_email_list(emails) when is_list(emails) do
    invalid = Enum.reject(emails, &Regex.match?(@email_regex, &1))

    if invalid == [] do
      :ok
    else
      {:error, "Invalid email addresses: #{Enum.join(invalid, ", ")}"}
    end
  end
  defp validate_email_list(_), do: {:error, "Email list must be an array"}

  defp validate_string(nil, opts), do: if(Keyword.get(opts, :required), do: {:error, "String is required"}, else: :ok)
  defp validate_string(str, opts) when is_binary(str) do
    min = Keyword.get(opts, :min, 0)
    max = Keyword.get(opts, :max, 1_000_000)

    cond do
      String.length(str) < min -> {:error, "String too short (minimum #{min} characters)"}
      String.length(str) > max -> {:error, "String too long (maximum #{max} characters)"}
      true -> :ok
    end
  end
  defp validate_string(_, _), do: {:error, "Value must be a string"}

  defp validate_integer(nil, opts) do
    if default = Keyword.get(opts, :default) do
      {:ok, default}
    else
      :ok
    end
  end
  defp validate_integer(int, opts) when is_integer(int) do
    min = Keyword.get(opts, :min, 0)
    max = Keyword.get(opts, :max, 1_000_000)

    cond do
      int < min -> {:error, "Value too small (minimum #{min})"}
      int > max -> {:error, "Value too large (maximum #{max})"}
      true -> :ok
    end
  end
  defp validate_integer(_, _), do: {:error, "Value must be an integer"}

  defp validate_datetime(nil), do: :ok
  defp validate_datetime(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, _dt, _offset} -> :ok
      {:error, _} -> {:error, "Invalid datetime format. Use ISO 8601 format"}
    end
  end
  defp validate_datetime(_), do: {:error, "Datetime must be a string in ISO 8601 format"}

  defp validate_datetime_order(start_str, end_str) do
    with {:ok, start_dt, _} <- DateTime.from_iso8601(start_str),
         {:ok, end_dt, _} <- DateTime.from_iso8601(end_str) do
      if DateTime.compare(start_dt, end_dt) == :lt do
        :ok
      else
        {:error, "End time must be after start time"}
      end
    else
      _ -> :ok  # Skip if parsing fails, already caught by validate_datetime
    end
  end

  defp validate_phone(nil), do: :ok
  defp validate_phone(phone) when is_binary(phone) do
    # Basic phone validation - just check it has some digits
    if String.match?(phone, ~r/\d{3,}/) do
      :ok
    else
      {:error, "Invalid phone number format"}
    end
  end
  defp validate_phone(_), do: {:error, "Phone must be a string"}

  defp validate_map(nil), do: {:error, "Properties are required"}
  defp validate_map(map) when is_map(map) and map != %{}, do: :ok
  defp validate_map(_), do: {:error, "Properties must be a non-empty object"}

  defp validate_meeting_times(nil), do: :ok
  defp validate_meeting_times(times) when is_list(times) do
    Enum.reduce_while(times, :ok, fn time, _acc ->
      if is_map(time) && is_binary(time["date"]) && is_binary(time["time"]) do
        {:cont, :ok}
      else
        {:halt, {:error, "Invalid meeting time format"}}
      end
    end)
  end
  defp validate_meeting_times(_), do: {:error, "Meeting times must be an array"}

  defp validate_source_types(nil), do: :ok
  defp validate_source_types(types) when is_list(types) do
    valid_types = ["gmail", "hubspot_contact", "hubspot_note", "calendar"]
    invalid = Enum.reject(types, &(&1 in valid_types))

    if invalid == [] do
      :ok
    else
      {:error, "Invalid source types: #{Enum.join(invalid, ", ")}"}
    end
  end
  defp validate_source_types(_), do: {:error, "Source types must be an array"}
end
