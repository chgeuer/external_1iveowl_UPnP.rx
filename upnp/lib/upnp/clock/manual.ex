defmodule UPnP.Clock.Manual do
  @moduledoc """
  A manually advanced clock for deterministic protocol tests.

  Pass `{UPnP.Clock.Manual, pid}` as a control point's `:clock`.
  """

  use GenServer

  @behaviour UPnP.Clock

  @type state :: %{
          now: non_neg_integer(),
          utc: DateTime.t(),
          next_sequence: non_neg_integer(),
          timers: %{
            reference() => {non_neg_integer(), non_neg_integer(), Process.dest(), term()}
          }
        }

  @doc "Starts a manual clock at the supplied UTC instant."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options)
  end

  @doc "Advances the clock and delivers every timer due at or before the new time."
  @spec advance(GenServer.server(), non_neg_integer()) :: :ok
  def advance(clock, milliseconds) when is_integer(milliseconds) and milliseconds >= 0 do
    GenServer.call(clock, {:advance, milliseconds})
  end

  @impl UPnP.Clock
  def monotonic_time(clock), do: GenServer.call(clock, :monotonic_time)

  @impl UPnP.Clock
  def utc_now(clock), do: GenServer.call(clock, :utc_now)

  @impl UPnP.Clock
  def send_after(clock, destination, message, milliseconds) do
    GenServer.call(clock, {:send_after, destination, message, milliseconds})
  end

  @impl UPnP.Clock
  def cancel_timer(clock, timer_ref) do
    GenServer.call(clock, {:cancel_timer, timer_ref})
  end

  @impl true
  def init(options) do
    utc = Keyword.get(options, :utc_now, ~U[2000-01-01 00:00:00Z])
    {:ok, %{now: 0, utc: utc, next_sequence: 0, timers: %{}}}
  end

  @impl true
  def handle_call(:monotonic_time, _from, state), do: {:reply, state.now, state}

  def handle_call(:utc_now, _from, state), do: {:reply, state.utc, state}

  def handle_call({:send_after, destination, message, milliseconds}, _from, state) do
    timer_ref = make_ref()
    timer = {state.now + milliseconds, state.next_sequence, destination, message}

    {:reply, timer_ref,
     %{
       state
       | next_sequence: state.next_sequence + 1,
         timers: Map.put(state.timers, timer_ref, timer)
     }}
  end

  def handle_call({:cancel_timer, timer_ref}, _from, state) do
    case Map.pop(state.timers, timer_ref) do
      {nil, _timers} ->
        {:reply, false, state}

      {{due_at, _sequence, _destination, _message}, timers} ->
        {:reply, max(due_at - state.now, 0), %{state | timers: timers}}
    end
  end

  def handle_call({:advance, milliseconds}, _from, state) do
    now = state.now + milliseconds

    {due, pending} =
      Enum.split_with(state.timers, fn
        {_ref, {due_at, _sequence, _destination, _message}} -> due_at <= now
      end)

    due
    |> Enum.sort_by(fn {_ref, {due_at, sequence, _destination, _message}} ->
      {due_at, sequence}
    end)
    |> Enum.each(fn {_ref, {_due_at, _sequence, destination, message}} ->
      send(destination, message)
    end)

    {:reply, :ok,
     %{
       state
       | now: now,
         utc: DateTime.add(state.utc, milliseconds, :millisecond),
         timers: Map.new(pending)
     }}
  end
end
