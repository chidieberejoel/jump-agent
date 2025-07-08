defmodule JumpAgent.Workers.GmailSyncWorker do
  @moduledoc """
  Syncs emails from Gmail and creates embeddings for RAG.
  """

  use Oban.Worker, queue: :sync

  alias JumpAgent.{Accounts, GoogleAPI, AI}
  alias JumpAgent.AI.EmbeddingService
  require Logger

  @impl Oban.Worker
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
          process_email(user, message_id)
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

  defp process_email(user, message_id) do
    # Check if we already have this email
    existing = AI.VectorSearch.find_by_source(user.id, "gmail", message_id)

    if is_nil(existing) do
      # Fetch full email details
      case GoogleAPI.get_email(user, message_id) do
        {:ok, email} ->
          create_email_embedding(user, email)
        {:error, reason} ->
          Logger.error("Failed to fetch email #{message_id}: #{inspect(reason)}")
      end
    end
  end

  defp create_email_embedding(user, email) do
    # Extract email content
    content = extract_email_content(email)
    metadata = extract_email_metadata(email)

    if content && content != "" do
      # Prepare content with metadata
      prepared_content = EmbeddingService.prepare_content(content, metadata)

      # Create embedding
      AI.upsert_document_embedding(user, %{
        source_type: "gmail",
        source_id: email["id"],
        content: prepared_content,
        metadata: metadata,
        created_at_source: parse_email_date(email["internalDate"])
      })
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
        Base.url_decode64!(payload["body"]["data"], padding: false)

      payload["parts"] ->
        Enum.find_value(payload["parts"], fn part ->
          find_part_content(part, mime_type)
        end)

      true ->
        nil
    end
  end

  defp extract_email_metadata(email) do
    headers = email["payload"]["headers"] || []

    %{
      "subject" => get_header(headers, "Subject"),
      "from" => get_header(headers, "From"),
      "to" => get_header(headers, "To"),
      "date" => get_header(headers, "Date"),
      "snippet" => email["snippet"]
    }
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
