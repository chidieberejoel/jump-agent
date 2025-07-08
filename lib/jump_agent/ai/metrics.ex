defmodule JumpAgent.AI.Metrics do
  @moduledoc """
  Tracks metrics for AI operations.
  """

  use GenServer
  require Logger

  @cleanup_interval :timer.hours(24)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    schedule_cleanup()
    {:ok, %{
      requests: %{},
      errors: %{},
      latencies: [],
      token_usage: %{}
    }}
  end

  # Public API

  def track_request(user_id, type, duration_ms, tokens \\ nil) do
    GenServer.cast(__MODULE__, {:track_request, user_id, type, duration_ms, tokens})
  end

  def track_error(user_id, type, error) do
    GenServer.cast(__MODULE__, {:track_error, user_id, type, error})
  end

  def get_stats(user_id \\ nil) do
    GenServer.call(__MODULE__, {:get_stats, user_id})
  end

  def get_health_status do
    GenServer.call(__MODULE__, :get_health_status)
  end

  # Server callbacks

  def handle_cast({:track_request, user_id, type, duration_ms, tokens}, state) do
    now = DateTime.utc_now()

    # Update request counts
    requests = Map.update(state.requests, {user_id, type, Date.utc_today()}, 1, &(&1 + 1))

    # Update latencies (keep last 100)
    latencies = [{type, duration_ms, now} | state.latencies] |> Enum.take(100)

    # Update token usage if provided
    token_usage =
      if tokens do
        Map.update(state.token_usage, {user_id, Date.utc_today()}, tokens, &(&1 + tokens))
      else
        state.token_usage
      end

    {:noreply, %{state |
      requests: requests,
      latencies: latencies,
      token_usage: token_usage
    }}
  end

  def handle_cast({:track_error, user_id, type, error}, state) do
    errors = Map.update(state.errors, {user_id, type, Date.utc_today()}, 1, &(&1 + 1))

    Logger.warning("AI error for user #{user_id}, type #{type}: #{inspect(error)}")

    {:noreply, %{state | errors: errors}}
  end

  def handle_call({:get_stats, user_id}, _from, state) do
    stats = build_stats(state, user_id)
    {:reply, stats, state}
  end

  def handle_call(:get_health_status, _from, state) do
    status = calculate_health_status(state)
    {:reply, status, state}
  end

  def handle_info(:cleanup, state) do
    # Remove old data (older than 30 days)
    cutoff = Date.add(Date.utc_today(), -30)

    requests = filter_by_date(state.requests, cutoff)
    errors = filter_by_date(state.errors, cutoff)
    token_usage = filter_by_date(state.token_usage, cutoff)

    schedule_cleanup()

    {:noreply, %{state |
      requests: requests,
      errors: errors,
      token_usage: token_usage
    }}
  end

  # Private functions

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp filter_by_date(map, cutoff) do
    map
    |> Enum.filter(fn
      {{_, _, date}, _} -> Date.compare(date, cutoff) == :gt
      _ -> true
    end)
    |> Map.new()
  end

  defp build_stats(state, nil) do
    %{
      total_requests: map_size(state.requests),
      total_errors: map_size(state.errors),
      recent_latencies: calculate_latency_stats(state.latencies),
      token_usage_today: calculate_today_tokens(state.token_usage),
      health_status: calculate_health_status(state)
    }
  end

  defp build_stats(state, user_id) do
    user_requests =
      state.requests
      |> Enum.filter(fn {{uid, _, _}, _} -> uid == user_id end)
      |> Map.new()

    user_errors =
      state.errors
      |> Enum.filter(fn {{uid, _, _}, _} -> uid == user_id end)
      |> Map.new()

    user_tokens =
      state.token_usage
      |> Enum.filter(fn {{uid, _}, _} -> uid == user_id end)
      |> Map.new()

    %{
      requests_today: calculate_today_count(user_requests),
      errors_today: calculate_today_count(user_errors),
      tokens_today: calculate_today_tokens(user_tokens),
      request_types: group_by_type(user_requests),
      error_types: group_by_type(user_errors)
    }
  end

  defp calculate_latency_stats([]), do: %{avg: 0, p95: 0, p99: 0}
  defp calculate_latency_stats(latencies) do
    sorted =
      latencies
      |> Enum.map(fn {_, duration, _} -> duration end)
      |> Enum.sort()

    count = length(sorted)
    avg = Enum.sum(sorted) / count
    p95 = Enum.at(sorted, round(count * 0.95))
    p99 = Enum.at(sorted, round(count * 0.99))

    %{avg: round(avg), p95: p95, p99: p99}
  end

  defp calculate_today_count(map) do
    today = Date.utc_today()

    map
    |> Enum.filter(fn {{_, _, date}, _} -> date == today end)
    |> Enum.map(fn {_, count} -> count end)
    |> Enum.sum()
  end

  defp calculate_today_tokens(map) do
    today = Date.utc_today()

    map
    |> Enum.filter(fn {{_, date}, _} -> date == today end)
    |> Enum.map(fn {_, tokens} -> tokens end)
    |> Enum.sum()
  end

  defp group_by_type(map) do
    map
    |> Enum.group_by(fn {{_, type, _}, _} -> type end, fn {_, count} -> count end)
    |> Enum.map(fn {type, counts} -> {type, Enum.sum(counts)} end)
    |> Map.new()
  end

  defp calculate_health_status(state) do
    # Simple health check based on error rate
    recent_errors = calculate_today_count(state.errors)
    recent_requests = calculate_today_count(state.requests)

    error_rate = if recent_requests > 0, do: recent_errors / recent_requests, else: 0

    cond do
      error_rate > 0.1 -> :unhealthy
      error_rate > 0.05 -> :degraded
      true -> :healthy
    end
  end
end
