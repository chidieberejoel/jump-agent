defmodule JumpAgent.AI.OpenAIClient do
  @moduledoc """
  Centralized OpenAI client with connection pooling and rate limiting.
  """

  use GenServer
  require Logger

  @rate_limit_delay 1000 # 1 second between requests
  @max_retries 3

  def start_link(opts \\ []) do
    # Use a unique name if provided in opts, otherwise use the module name
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def init(_opts) do
    api_key = Application.get_env(:openai_ex, :api_key)

    if is_nil(api_key) || api_key == "" do
      Logger.warning("OpenAI API key not configured - OpenAI features will be disabled")
      {:ok, %{
        last_request: 0,
        request_queue: :queue.new(),
        processing: false,
        api_available: false
      }}
    else
      Logger.info("OpenAI client initialized with API key")
      {:ok, %{
        last_request: 0,
        request_queue: :queue.new(),
        processing: false,
        api_available: true
      }}
    end
  end

  # Public API

  def chat_completion(messages, tools \\ nil, opts \\ []) do
    GenServer.call(__MODULE__, {:chat_completion, messages, tools, opts}, 60_000)
  end

  def create_embedding(text) do
    GenServer.call(__MODULE__, {:create_embedding, text}, 30_000)
  end

  def create_embeddings(texts) when is_list(texts) do
    GenServer.call(__MODULE__, {:create_embeddings, texts}, 60_000)
  end

  # Server callbacks

  def handle_call({:chat_completion, messages, tools, opts}, from, state) do
    if state.api_available do
      request = {:chat, messages, tools, opts, from}
      state = enqueue_request(request, state)
      {:noreply, process_queue(state)}
    else
      {:reply, {:error, :no_api_key}, state}
    end
  end

  def handle_call({:create_embedding, text}, from, state) do
    if state.api_available do
      request = {:embedding, text, from}
      state = enqueue_request(request, state)
      {:noreply, process_queue(state)}
    else
      {:reply, {:error, :no_api_key}, state}
    end
  end

  def handle_call({:create_embeddings, texts}, from, state) do
    if state.api_available do
      request = {:embeddings, texts, from}
      state = enqueue_request(request, state)
      {:noreply, process_queue(state)}
    else
      {:reply, {:error, :no_api_key}, state}
    end
  end

  def handle_info(:process_next, state) do
    {:noreply, process_queue(%{state | processing: false})}
  end

  # Private functions

  defp enqueue_request(request, state) do
    %{state | request_queue: :queue.in(request, state.request_queue)}
  end

  defp process_queue(%{processing: true} = state), do: state
  defp process_queue(state) do
    case :queue.out(state.request_queue) do
      {{:value, request}, new_queue} ->
        now = System.monotonic_time(:millisecond)
        delay = calculate_delay(state.last_request, now)

        if delay > 0 do
          Process.send_after(self(), :process_next, delay)
          %{state | request_queue: new_queue, processing: true}
        else
          process_request(request)
          %{state |
            request_queue: new_queue,
            last_request: now,
            processing: false
          } |> process_queue()
        end

      {:empty, _} ->
        state
    end
  end

  defp calculate_delay(last_request, now) do
    elapsed = now - last_request
    if elapsed < @rate_limit_delay do
      @rate_limit_delay - elapsed
    else
      0
    end
  end

  defp process_request({:chat, messages, tools, opts, from}) do
    result = do_chat_completion(messages, tools, opts)
    GenServer.reply(from, result)
  end

  defp process_request({:embedding, text, from}) do
    result = do_create_embedding(text)
    GenServer.reply(from, result)
  end

  defp process_request({:embeddings, texts, from}) do
    result = do_create_embeddings(texts)
    GenServer.reply(from, result)
  end

  defp do_chat_completion(messages, tools, opts, retry_count \\ 0) do
    api_key = Application.get_env(:openai_ex, :api_key)

    if is_nil(api_key) || api_key == "" do
      {:error, :no_api_key}
    else
      client = OpenaiEx.new(api_key: api_key)

      model = Keyword.get(opts, :model, "gpt-4-turbo")
      temperature = Keyword.get(opts, :temperature, 0.7)
      max_tokens = Keyword.get(opts, :max_tokens, 1000)

      # Build the request - ensure messages have proper format
      request = %{
        "model" => model,
        "messages" => messages,
        "temperature" => temperature,
        "max_tokens" => max_tokens
      }

      # Add tools if provided
      request = if tools do
        Map.merge(request, %{"tools" => tools, "tool_choice" => "auto"})
      else
        request
      end

      Logger.debug("OpenAI request: #{inspect(request)}")

      case OpenaiEx.Chat.create_completion(client, request) do
        {:ok, response} ->
          Logger.debug("OpenAI response: #{inspect(response)}")
          {:ok, response}

        {:error, %{status: 429}} when retry_count < @max_retries ->
          # Rate limited, wait and retry
          wait_time = (retry_count + 1) * 2000
          Logger.warning("OpenAI rate limit hit, waiting #{wait_time}ms before retry")
          Process.sleep(wait_time)
          do_chat_completion(messages, tools, opts, retry_count + 1)

        {:error, %{status: 401}} ->
          Logger.error("OpenAI authentication failed - check your API key")
          {:error, {:api_error, "Authentication failed. Please check your OpenAI API key."}}

        {:error, %{status: 400, body: body}} ->
          Logger.error("OpenAI bad request: #{inspect(body)}")
          error_msg = extract_error_message(body)
          {:error, {:api_error, error_msg}}

        {:error, %{status: status, body: body}} ->
          Logger.error("OpenAI API error (status #{status}): #{inspect(body)}")
          error_msg = extract_error_message(body)
          {:error, {:api_error, "API error (#{status}): #{error_msg}"}}

        {:error, reason} ->
          Logger.error("OpenAI request failed: #{inspect(reason)}")
          {:error, {:api_error, "Request failed: #{inspect(reason)}"}}
      end
    end
  end

  defp do_create_embedding(text, retry_count \\ 0) do
    api_key = Application.get_env(:openai_ex, :api_key)

    if is_nil(api_key) || api_key == "" do
      {:error, :no_api_key}
    else
      client = OpenaiEx.new(api_key: api_key)

      case OpenaiEx.Embeddings.create(client, %{
        "model" => "text-embedding-3-small",
        "input" => text
      }) do
        {:ok, %{"data" => [%{"embedding" => embedding} | _]}} ->
          {:ok, embedding}

        {:error, %{status: 429}} when retry_count < @max_retries ->
          Process.sleep((retry_count + 1) * 2000)
          do_create_embedding(text, retry_count + 1)

        {:error, reason} ->
          Logger.error("OpenAI embedding creation failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp do_create_embeddings(texts, retry_count \\ 0) do
    api_key = Application.get_env(:openai_ex, :api_key)

    if is_nil(api_key) || api_key == "" do
      {:error, :no_api_key}
    else
      client = OpenaiEx.new(api_key: api_key)

      case OpenaiEx.Embeddings.create(client, %{
        "model" => "text-embedding-3-small",
        "input" => texts
      }) do
        {:ok, %{"data" => embeddings}} ->
          vectors = Enum.map(embeddings, & &1["embedding"])
          {:ok, vectors}

        {:error, %{status: 429}} when retry_count < @max_retries ->
          Process.sleep((retry_count + 1) * 2000)
          do_create_embeddings(texts, retry_count + 1)

        {:error, reason} ->
          Logger.error("OpenAI embeddings creation failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp extract_error_message(%{"error" => %{"message" => message}}), do: message
  defp extract_error_message(body) when is_binary(body), do: body
  defp extract_error_message(_), do: "Unknown error"
end
