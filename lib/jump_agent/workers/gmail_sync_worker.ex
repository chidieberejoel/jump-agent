defmodule JumpAgent.Workers.GmailSyncWorker do
  @moduledoc """
  Syncs emails from Gmail, creates embeddings for RAG, and triggers instruction processing.
  """

  use Oban.Worker, queue: :sync

  alias JumpAgent.{Accounts, GoogleAPI, AI}
  alias JumpAgent.AI.EmbeddingService
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "history_id" => history_id}}) do
    # Perform targeted sync based on history_id
    case Accounts.get_user(user_id) do
      nil ->
        Logger.warning("User not found: #{user_id}")
        :ok

      user ->
        sync_user_emails_from_history(user, history_id)
    end
  end

  def perform(_job) do
    # Get all users with Google tokens
    users = Accounts.list_users_with_google_tokens()

    Enum.each(users, &sync_user_emails/1)

    :ok
  end

  defp sync_user_emails(user) do
    Logger.info("Syncing Gmail for user #{user.id}")

    # Get recent emails with pagination
    sync_emails_page(user, nil, 0)
  rescue
    error ->
      Logger.error("Gmail sync error for user #{user.id}: #{inspect(error)}")
  end

  defp sync_user_emails_from_history(user, history_id) do
    Logger.info("Syncing Gmail history for user #{user.id} from history ID: #{history_id}")

    # Use history API to get changes since last sync
    case GoogleAPI.list_history(user, history_id) do
      {:ok, %{"history" => history_records}} when is_list(history_records) ->
        Enum.each(history_records, fn record ->
          if messages_added = record["messagesAdded"] do
            Enum.each(messages_added, fn %{"message" => %{"id" => message_id}} ->
              process_email(user, message_id, true)
            end)
          end
        end)

      {:error, reason} ->
        Logger.error("Failed to sync Gmail history: #{inspect(reason)}")
        # Fall back to regular sync
        sync_user_emails(user)
    end
  end

  defp sync_emails_page(user, page_token, processed_count) when processed_count >= 200 do
    Logger.info("Reached sync limit of 200 emails for user #{user.id}")
    :ok
  end

  defp sync_emails_page(user, page_token, processed_count) do
    opts = [maxResults: 50]
    opts = if page_token, do: Keyword.put(opts, :pageToken, page_token), else: opts

    case GoogleAPI.list_emails(user, opts) do
      {:ok, %{"messages" => messages} = response} when is_list(messages) ->
        # Process each email
        Enum.each(messages, fn %{"id" => message_id} ->
          process_email(user, message_id, false)
        end)

        # Continue with next page if available
        case response do
          %{"nextPageToken" => next_token} when is_binary(next_token) ->
            sync_emails_page(user, next_token, processed_count + length(messages))
          _ ->
            :ok
        end

      {:error, :unauthorized} ->
        Logger.warning("Gmail sync failed for user #{user.id}: unauthorized")

      {:error, reason} ->
        Logger.error("Gmail sync failed for user #{user.id}: #{inspect(reason)}")
    end
  end

  defp process_email(user, message_id, is_new_email) do
    # Check if we already have this email
    existing = AI.VectorSearch.find_by_source(user.id, "gmail", message_id)

    if is_nil(existing) || is_new_email do
      # Fetch full email details
      case GoogleAPI.get_email(user, message_id) do
        {:ok, email} ->
          # Create embedding
          create_email_embedding(user, email)

          # Trigger instruction processing for new emails
          if is_new_email || is_nil(existing) do
            trigger_email_instructions(user, email)
          end

        {:error, reason} ->
          Logger.error("Failed to fetch email #{message_id}: #{inspect(reason)}")
      end
    end
  end

  defp trigger_email_instructions(user, email) do
    # Extract email data for instruction processing
    email_data = %{
      "message_id" => email["id"],
      "thread_id" => email["threadId"],
      "from" => extract_sender(email),
      "to" => extract_recipients(email),
      "cc" => extract_cc(email),
      "subject" => extract_subject(email),
      "content" => extract_email_content(email),
      "snippet" => email["snippet"],
      "date" => parse_email_date(email["internalDate"]),
      "labels" => email["labelIds"] || [],
      "has_attachments" => has_attachments?(email)
    }

    # Process external event to trigger any matching instructions
    Logger.info("Processing email_received event for instruction triggers")
    AI.process_external_event(user, "email_received", email_data)
  end

  defp create_email_embedding(user, email) do
    # Extract email content
    content = extract_email_content(email)
    metadata = extract_email_metadata(email)

    if content && content != "" do
      # Prepare content with metadata
      prepared_content = EmbeddingService.prepare_content(content, metadata)

      # Create embedding - this will now handle failures gracefully
      case AI.upsert_document_embedding(user, %{
        source_type: "gmail",
        source_id: email["id"],
        content: prepared_content,
        metadata: metadata,
        created_at_source: parse_email_date(email["internalDate"])
      }) do
        {:ok, _embedding} ->
          Logger.debug("Created embedding for email #{email["id"]}")
        {:error, reason} ->
          Logger.warning("Failed to create embedding for email #{email["id"]}: #{inspect(reason)}")
      end
    end
  end

  defp extract_email_content(email) do
    payload = email["payload"]

    # Try to find text/plain part
    text_content = find_part_content(payload, "text/plain")

    # Fall back to text/html if no plain text
    if text_content do
      text_content
    else
      html_content = find_part_content(payload, "text/html")
      if html_content do
        # Strip HTML tags (simple version)
        html_content
        |> String.replace(~r/<[^>]*>/, " ")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
      end
    end
  end

  defp find_part_content(payload, mime_type) do
    cond do
      payload["mimeType"] == mime_type && payload["body"]["data"] ->
        decode_base64_body(payload["body"]["data"])

      payload["parts"] ->
        Enum.find_value(payload["parts"], fn part ->
          find_part_content(part, mime_type)
        end)

      true ->
        nil
    end
  end

  defp decode_base64_body(data) do
    case Base.url_decode64(data, padding: false) do
      {:ok, decoded} -> decoded
      {:error, _} ->
        # Try with padding if the first attempt fails
        case Base.url_decode64(data) do
          {:ok, decoded} -> decoded
          {:error, _} -> nil
        end
    end
  end

  defp extract_email_metadata(email) do
    headers = email["payload"]["headers"] || []

    %{
      "subject" => get_header(headers, "Subject"),
      "from" => get_header(headers, "From"),
      "to" => get_header(headers, "To"),
      "cc" => get_header(headers, "Cc"),
      "date" => get_header(headers, "Date"),
      "snippet" => email["snippet"]
    }
  end

  defp extract_sender(email) do
    headers = email["payload"]["headers"] || []
    get_header(headers, "From")
  end

  defp extract_recipients(email) do
    headers = email["payload"]["headers"] || []
    to_header = get_header(headers, "To")

    if to_header do
      to_header
      |> String.split(",")
      |> Enum.map(&String.trim/1)
    else
      []
    end
  end

  defp extract_cc(email) do
    headers = email["payload"]["headers"] || []
    cc_header = get_header(headers, "Cc")

    if cc_header do
      cc_header
      |> String.split(",")
      |> Enum.map(&String.trim/1)
    else
      []
    end
  end

  defp extract_subject(email) do
    headers = email["payload"]["headers"] || []
    get_header(headers, "Subject") || "(No Subject)"
  end

  defp has_attachments?(email) do
    check_parts_for_attachments(email["payload"])
  end

  defp check_parts_for_attachments(payload) do
    cond do
      payload["filename"] && payload["filename"] != "" ->
        true

      payload["parts"] ->
        Enum.any?(payload["parts"], &check_parts_for_attachments/1)

      true ->
        false
    end
  end

  defp get_header(headers, name) do
    case Enum.find(headers, fn h -> h["name"] == name end) do
      %{"value" => value} -> value
      _ -> nil
    end
  end

  defp parse_email_date(internal_date) when is_binary(internal_date) do
    internal_date
    |> String.to_integer()
    |> DateTime.from_unix!(:millisecond)
  end
  defp parse_email_date(_), do: DateTime.utc_now()
end
