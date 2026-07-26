defmodule UPnP.IGD.Lease.Worker do
  @moduledoc false

  use GenServer, restart: :temporary

  alias UPnP.{Clock, Subscription}
  alias UPnP.IGD.{Gateway, LeaseEvent}

  def child_spec(options) do
    %{super(options) | id: {__MODULE__, make_ref()}, restart: :temporary}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    owner = Keyword.fetch!(options, :owner)
    mapping = Keyword.fetch!(options, :mapping)
    clock = Keyword.fetch!(options, :clock)

    state = %{
      gateway: Keyword.fetch!(options, :gateway),
      mapping: mapping,
      clock: clock,
      action_options: Keyword.get(options, :action_options, []),
      owner_monitor: Process.monitor(owner),
      subscribers: %{},
      subscriber_monitors: %{},
      timer: nil,
      renewal_task: nil,
      last_success: Clock.monotonic_time(clock),
      expired?: false
    }

    {:ok, schedule_renewal(state)}
  end

  @impl true
  def handle_call({:subscribe, subscriber}, _from, state) when is_pid(subscriber) do
    ref = make_ref()
    monitor = Process.monitor(subscriber)
    subscription = %Subscription{server: self(), ref: ref, kind: :igd_lease}
    subscribers = Map.put(state.subscribers, ref, %{pid: subscriber, monitor: monitor})
    monitors = Map.put(state.subscriber_monitors, monitor, ref)

    {:reply, {:ok, subscription},
     %{state | subscribers: subscribers, subscriber_monitors: monitors}}
  end

  def handle_call({:unsubscribe, ref}, _from, state) do
    {:reply, :ok, remove_subscriber(state, ref)}
  end

  def handle_call(:close, _from, state) do
    state = cancel_work(state)

    result =
      Gateway.delete_port_mapping(
        state.gateway,
        state.mapping.external_port,
        state.mapping.protocol,
        state.action_options
      )
      |> normalize_close_result()

    {:stop, :normal, result, state}
  end

  def handle_call(:abandon, _from, state) do
    {:stop, :normal, :ok, cancel_work(state)}
  end

  @impl true
  def handle_info(:renew, %{renewal_task: nil} = state) do
    task =
      Task.Supervisor.async_nolink(UPnP.TaskSupervisor, fn ->
        Gateway.renew(state.gateway, state.mapping, state.action_options)
      end)

    {:noreply, %{state | timer: nil, renewal_task: task}}
  end

  def handle_info(:renew, state), do: {:noreply, state}

  def handle_info({ref, result}, %{renewal_task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | renewal_task: nil}
    {:noreply, complete_renewal(state, result)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{renewal_task: %{ref: ref}} = state
      ) do
    state = %{state | renewal_task: nil}
    {:noreply, complete_renewal(state, {:error, {:task_exit, reason}})}
  end

  def handle_info(
        {:DOWN, owner_monitor, :process, _pid, _reason},
        %{owner_monitor: owner_monitor} = state
      ) do
    {:stop, :normal, cancel_work(state)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case state.subscriber_monitors[monitor] do
      nil -> {:noreply, state}
      ref -> {:noreply, remove_subscriber(state, ref)}
    end
  end

  defp complete_renewal(state, :ok) do
    state =
      %{
        state
        | last_success: Clock.monotonic_time(state.clock),
          expired?: false
      }
      |> schedule_renewal()

    broadcast(state, %LeaseEvent{kind: :renewed})
    state
  end

  defp complete_renewal(state, {:error, reason}) do
    elapsed = Clock.monotonic_time(state.clock) - state.last_success
    lease_milliseconds = state.mapping.lease_duration * 1_000

    expired_now? = not state.expired? and elapsed > lease_milliseconds
    state = if expired_now?, do: %{state | expired?: true}, else: state
    state = schedule_renewal(state)

    broadcast(state, %LeaseEvent{kind: :renewal_failed, reason: reason})
    if expired_now?, do: broadcast(state, %LeaseEvent{kind: :expired, reason: reason})
    state
  end

  defp schedule_renewal(%{mapping: %{lease_duration: 0}} = state), do: state

  defp schedule_renewal(%{timer: nil, renewal_task: nil} = state) do
    interval = max(div(state.mapping.lease_duration * 1_000, 2), 1_000)
    timer = Clock.send_after(state.clock, self(), :renew, interval)
    %{state | timer: timer}
  end

  defp schedule_renewal(state), do: state

  defp cancel_work(state) do
    if state.timer, do: Clock.cancel_timer(state.clock, state.timer)
    if state.renewal_task, do: Task.shutdown(state.renewal_task, :brutal_kill)
    %{state | timer: nil, renewal_task: nil}
  end

  defp broadcast(state, event) do
    :telemetry.execute([:upnp, :igd, :lease], %{count: 1}, %{
      kind: event.kind,
      reason: UPnP.Telemetry.classify_error(event.reason),
      external_port: state.mapping.external_port,
      protocol: state.mapping.protocol
    })

    Enum.each(state.subscribers, fn {ref, %{pid: pid}} ->
      send(pid, {:upnp, ref, event})
    end)
  end

  defp remove_subscriber(state, ref) do
    case Map.pop(state.subscribers, ref) do
      {nil, _subscribers} ->
        state

      {%{monitor: monitor}, subscribers} ->
        Process.demonitor(monitor, [:flush])

        %{
          state
          | subscribers: subscribers,
            subscriber_monitors: Map.delete(state.subscriber_monitors, monitor)
        }
    end
  end

  defp normalize_close_result({:error, {:upnp_error, %UPnP.UpnpError{code: 714}}}),
    do: :ok

  defp normalize_close_result(result), do: result
end
