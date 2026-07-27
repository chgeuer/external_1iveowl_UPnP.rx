defmodule UPnP.ControlPoint.Owner do
  @moduledoc false

  use GenServer

  alias UPnP.ControlPoint.{Reaper, Runtime}
  alias UPnP.Eventing.Lifecycle
  alias UPnP.Subscription.Closed

  @recovery_backoff [1_000, 2_000, 4_000, 8_000, 16_000, 30_000]
  @healthy_after 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    {name, options} = Keyword.pop(options, :name)
    genserver_options = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, options, genserver_options)
  end

  @spec coordinator(GenServer.server()) ::
          {:ok, pid()} | {:error, :control_point_restarting}
  def coordinator(owner), do: GenServer.call(owner, :coordinator)

  @spec close(GenServer.server(), timeout()) :: :ok
  def close(owner, timeout), do: GenServer.call(owner, :close, timeout)

  @spec coordinator_started(pid(), Runtime.id(), pid(), pid()) :: :ok
  def coordinator_started(owner, id, runtime, coordinator) do
    send(owner, {:control_point_coordinator_started, id, runtime, coordinator})
    :ok
  end

  @spec runtime_started(pid(), Runtime.id(), pid()) :: :ok
  def runtime_started(owner, id, runtime) do
    send(owner, {:control_point_runtime_started, id, runtime})
    :ok
  end

  @spec track_subscription(pid(), pid(), reference(), atom(), pid()) ::
          :ok | {:error, :control_point_restarting}
  def track_subscription(owner, coordinator, ref, kind, subscriber) do
    GenServer.call(owner, {:track_subscription, coordinator, ref, kind, subscriber})
  end

  @spec untrack_subscription(pid(), reference()) :: :ok
  def untrack_subscription(owner, ref) do
    GenServer.call(owner, {:untrack_subscription, ref})
  catch
    :exit, {:noproc, _reason} -> :ok
    :exit, {:normal, _reason} -> :ok
    :exit, {:shutdown, _reason} -> :ok
  end

  @spec close_tracked_subscriptions(pid(), [reference()], atom()) ::
          :ok | {:error, :control_point_restarting}
  def close_tracked_subscriptions(owner, refs, reason) do
    GenServer.call(owner, {:close_tracked_subscriptions, refs, reason})
  catch
    :exit, _reason -> {:error, :control_point_restarting}
  end

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    id = make_ref()

    with {:ok, parsed_options} <- UPnP.Options.new(options),
         :ok <- Runtime.register(id, :owner),
         {:ok, generation_supervisor} <-
           DynamicSupervisor.start_link(
             strategy: :one_for_one,
             name: Runtime.name(id, :generations)
           ),
         {:ok, reaper} <-
           Reaper.start(self(), id, generation_supervisor, parsed_options.clock) do
      state = %{
        id: id,
        options: options,
        clock: parsed_options.clock,
        generation_supervisor: generation_supervisor,
        reaper: reaper,
        reaper_monitor: Process.monitor(reaper),
        runtime: nil,
        runtime_monitor: nil,
        runtime_start: nil,
        coordinator: nil,
        coordinator_monitor: nil,
        subscriptions: %{},
        subscription_monitors: %{},
        timer: nil,
        backoff_index: 0,
        closing: []
      }

      case start_runtime(state) do
        {:ok, state} -> {:ok, state}
        {:error, reason, _state} -> {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:coordinator, _from, state) do
    state = refresh_runtime(state)

    reply =
      if state.closing == [] and is_pid(state.coordinator) and
           Process.alive?(state.coordinator) do
        {:ok, state.coordinator}
      else
        {:error, :control_point_restarting}
      end

    {:reply, reply, state}
  end

  def handle_call(:close, from, %{closing: []} = state) do
    state = %{state | closing: [from]}

    if is_pid(state.coordinator) and Process.alive?(state.coordinator) do
      GenServer.cast(state.coordinator, :close)
      {:noreply, state}
    else
      state =
        state
        |> cancel_timer()
        |> close_subscriptions(:graceful_close)

      {:stop, :shutdown, :ok, state}
    end
  end

  def handle_call(:close, from, state) do
    {:noreply, %{state | closing: [from | state.closing]}}
  end

  def handle_call(
        {:track_subscription, coordinator, ref, kind, subscriber},
        _from,
        %{coordinator: coordinator, closing: []} = state
      )
      when is_pid(subscriber) do
    case Reaper.track_subscription(state.reaper, ref, kind, subscriber) do
      :ok ->
        monitor = Process.monitor(subscriber)
        entry = %{pid: subscriber, monitor: monitor, kind: kind}

        {:reply, :ok,
         %{
           state
           | subscriptions: Map.put(state.subscriptions, ref, entry),
             subscription_monitors: Map.put(state.subscription_monitors, monitor, ref)
         }}

      {:error, :reaper_unavailable} ->
        {:reply, {:error, :control_point_restarting}, state}
    end
  end

  def handle_call({:track_subscription, _coordinator, _ref, _kind, _subscriber}, _from, state) do
    {:reply, {:error, :control_point_restarting}, state}
  end

  def handle_call({:untrack_subscription, ref}, _from, state) do
    :ok = Reaper.untrack_subscription(state.reaper, ref)
    {:reply, :ok, remove_subscription(state, ref)}
  end

  def handle_call({:close_tracked_subscriptions, refs, reason}, _from, state) do
    case Reaper.close_subscriptions(state.reaper, refs, reason) do
      :ok ->
        {:reply, :ok, Enum.reduce(refs, state, &remove_subscription(&2, &1))}

      {:error, :reaper_unavailable} ->
        {:reply, {:error, :control_point_restarting}, state}
    end
  end

  @impl true
  def handle_info(
        {:control_point_runtime_started, id, runtime},
        %{id: id, runtime: current_runtime} = state
      ) do
    if current_runtime == runtime or Runtime.whereis(id, :runtime) == runtime do
      {:noreply, monitor_runtime(state, runtime)}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:control_point_coordinator_started, id, runtime, coordinator},
        %{id: id, runtime: runtime, runtime_start: nil} = state
      ) do
    if Runtime.whereis(id, :coordinator) != coordinator or not Process.alive?(coordinator) do
      {:noreply, state}
    else
      state = publish_coordinator(state, coordinator)

      if state.closing == [] do
        {:noreply, state}
      else
        GenServer.cast(coordinator, :close)
        {:noreply, state}
      end
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, coordinator, _reason},
        %{coordinator: coordinator, coordinator_monitor: monitor} = state
      ) do
    state =
      state
      |> cancel_timer()
      |> close_subscriptions_for_lifecycle(state)
      |> clear_coordinator()

    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor, :process, runtime, _reason},
        %{runtime: runtime, runtime_monitor: monitor} = state
      ) do
    state =
      state
      |> cancel_timer()
      |> close_subscriptions_for_lifecycle(state)
      |> clear_runtime()

    if state.closing == [] do
      if state.runtime_start == nil do
        {:noreply, schedule_recovery(state)}
      else
        {:noreply, state}
      end
    else
      Enum.each(state.closing, &GenServer.reply(&1, :ok))
      {:stop, :shutdown, %{state | closing: []}}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, worker, _reason},
        %{runtime_start: {_token, worker, monitor}} = state
      ) do
    state = %{state | runtime_start: nil}
    runtime = state.runtime || Runtime.whereis(state.id, :runtime)
    Reaper.terminate_runtime(state.id, [self(), state.generation_supervisor, worker])

    state =
      if state.runtime == runtime do
        clear_runtime(state)
      else
        state
      end

    {:noreply, schedule_recovery(state)}
  end

  def handle_info(
        {:DOWN, monitor, :process, reaper, reason},
        %{reaper: reaper, reaper_monitor: monitor} = state
      ) do
    {:stop, {:reaper_exit, reason}, state}
  end

  def handle_info({:DOWN, monitor, :process, _subscriber, _reason}, state) do
    case state.subscription_monitors[monitor] do
      nil -> {:noreply, state}
      ref -> {:noreply, remove_subscription(state, ref, false)}
    end
  end

  def handle_info(
        {:runtime_start_result, token, {:ok, runtime}},
        %{runtime_start: {token, _worker, monitor}} = state
      ) do
    Process.demonitor(monitor, [:flush])
    state = %{state | runtime_start: nil}

    if Process.alive?(runtime) do
      coordinator = Runtime.whereis(state.id, :coordinator)

      state =
        state
        |> monitor_runtime(runtime)
        |> publish_coordinator(coordinator)

      if state.closing == [] do
        {:noreply, state}
      else
        if is_pid(coordinator), do: GenServer.cast(coordinator, :close)
        {:noreply, state}
      end
    else
      {:noreply, schedule_recovery(state)}
    end
  end

  def handle_info(
        {:runtime_start_result, token, {:error, _reason}},
        %{runtime_start: {token, _worker, monitor}} = state
      ) do
    Process.demonitor(monitor, [:flush])
    state = %{state | runtime_start: nil}
    {:noreply, schedule_recovery(state)}
  end

  def handle_info(
        {:coordinator_healthy, token, coordinator},
        %{timer: {:healthy, _timer, token}} = state
      ) do
    if state.coordinator == coordinator do
      {:noreply, %{state | timer: nil, backoff_index: 0}}
    else
      {:noreply, %{state | timer: nil}}
    end
  end

  def handle_info({:recover_runtime, token}, %{timer: {:recovery, _timer, token}} = state) do
    {:noreply, state |> Map.put(:timer, nil) |> begin_runtime_start()}
  end

  def handle_info(
        {:EXIT, generation_supervisor, reason},
        %{generation_supervisor: generation_supervisor} = state
      ) do
    {:stop, {:generation_supervisor_exit, reason}, state}
  end

  def handle_info({:control_point_coordinator_started, _id, _runtime, _coordinator}, state),
    do: {:noreply, state}

  def handle_info({:control_point_runtime_started, _id, _runtime}, state), do: {:noreply, state}
  def handle_info({:runtime_start_result, _token, _result}, state), do: {:noreply, state}
  def handle_info({:coordinator_healthy, _token, _coordinator}, state), do: {:noreply, state}
  def handle_info({:recover_runtime, _token}, state), do: {:noreply, state}
  def handle_info({:EXIT, _process, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    lifecycle_reason =
      if reason == :shutdown and state.closing != [] do
        :graceful_close
      else
        :terminal_stop
      end

    _state =
      state
      |> cancel_timer()
      |> terminate_subscriptions(lifecycle_reason)

    runtime_starting? = state.runtime_start != nil
    terminate_runtime_start(state.runtime_start)

    Reaper.terminate_generation(
      state.generation_supervisor,
      state.id,
      runtime_starting?
    )

    :ok
  end

  defp start_runtime(state) do
    case start_runtime_child(state) do
      {:ok, runtime} ->
        coordinator = Runtime.whereis(state.id, :coordinator)

        state =
          state
          |> monitor_runtime(runtime)
          |> publish_coordinator(coordinator)

        {:ok, state}

      {:error, reason} ->
        {:error, reason, clear_runtime(state)}
    end
  end

  defp begin_runtime_start(%{runtime_start: nil} = state) do
    owner = self()
    token = make_ref()
    generation_supervisor = state.generation_supervisor
    child_spec = runtime_child_spec(state)

    {worker, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            DynamicSupervisor.start_child(generation_supervisor, child_spec)
          catch
            :exit, reason -> {:error, reason}
          end

        send(owner, {:runtime_start_result, token, result})
      end)

    %{state | runtime_start: {token, worker, monitor}}
  end

  defp begin_runtime_start(state), do: state

  defp start_runtime_child(state) do
    DynamicSupervisor.start_child(state.generation_supervisor, runtime_child_spec(state))
  catch
    :exit, reason -> {:error, reason}
  end

  defp runtime_child_spec(state) do
    %{
      id: make_ref(),
      start: {Runtime, :start_link, [state.id, self(), state.options]},
      type: :supervisor,
      restart: :temporary,
      shutdown: 5_000
    }
  end

  defp schedule_recovery(state) do
    index = min(state.backoff_index, length(@recovery_backoff) - 1)
    delay = Enum.at(@recovery_backoff, index)
    next_index = min(index + 1, length(@recovery_backoff) - 1)

    state
    |> Map.put(:backoff_index, next_index)
    |> schedule_timer(:recovery, delay, :recover_runtime)
  end

  defp schedule_timer(state, kind, delay, message) do
    state = cancel_timer(state)
    token = make_ref()
    timer = UPnP.Clock.send_after(state.clock, self(), timer_message(message, token), delay)
    %{state | timer: {kind, timer, token}}
  end

  defp timer_message({:coordinator_healthy, coordinator}, token),
    do: {:coordinator_healthy, token, coordinator}

  defp timer_message(:recover_runtime, token), do: {:recover_runtime, token}

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(state) do
    {_kind, timer, _token} = state.timer
    UPnP.Clock.cancel_timer(state.clock, timer)
    %{state | timer: nil}
  end

  defp publish_coordinator(%{coordinator: coordinator} = state, coordinator)
       when is_pid(coordinator),
       do: state

  defp publish_coordinator(state, coordinator) when is_pid(coordinator) do
    state =
      if is_pid(state.coordinator) do
        close_subscriptions_for_lifecycle(state, state)
      else
        state
      end

    state
    |> cancel_timer()
    |> clear_coordinator()
    |> Map.merge(%{
      coordinator: coordinator,
      coordinator_monitor: Process.monitor(coordinator)
    })
    |> schedule_timer(:healthy, @healthy_after, {:coordinator_healthy, coordinator})
  end

  defp publish_coordinator(state, _coordinator), do: clear_coordinator(state)

  defp monitor_runtime(%{runtime: runtime} = state, runtime), do: state

  defp monitor_runtime(state, runtime) when is_pid(runtime) do
    state = clear_runtime(state)
    %{state | runtime: runtime, runtime_monitor: Process.monitor(runtime)}
  end

  defp refresh_runtime(%{closing: [_caller | _callers]} = state), do: state

  defp refresh_runtime(%{runtime: runtime} = state) when is_pid(runtime) do
    if Process.alive?(runtime) do
      state
    else
      state =
        state
        |> cancel_timer()
        |> close_subscriptions_for_lifecycle(state)
        |> clear_runtime()

      if state.closing == [], do: schedule_recovery(state), else: state
    end
  end

  defp refresh_runtime(state), do: state

  defp clear_coordinator(%{coordinator_monitor: nil} = state) do
    %{state | coordinator: nil}
  end

  defp clear_coordinator(state) do
    Process.demonitor(state.coordinator_monitor, [:flush])
    %{state | coordinator: nil, coordinator_monitor: nil}
  end

  defp clear_runtime(state) do
    if state.runtime_monitor do
      Process.demonitor(state.runtime_monitor, [:flush])
    end

    state
    |> clear_coordinator()
    |> Map.merge(%{runtime: nil, runtime_monitor: nil})
  end

  defp terminate_runtime_start(nil), do: :ok

  defp terminate_runtime_start({_token, worker, monitor}) do
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    end
  end

  defp lifecycle_reason(%{closing: []}), do: :internal_restart
  defp lifecycle_reason(_state), do: :graceful_close

  defp close_subscriptions(state, reason) do
    case Reaper.close_subscriptions(state.reaper, reason) do
      :ok -> clear_subscriptions(state)
      {:error, :reaper_unavailable} -> state
    end
  end

  defp close_subscriptions_for_lifecycle(state, lifecycle_state) do
    if terminal_dependency_failed?(state) do
      state
    else
      close_subscriptions(state, lifecycle_reason(lifecycle_state))
    end
  end

  defp terminate_subscriptions(state, reason) do
    case Reaper.close_subscriptions(state.reaper, reason) do
      :ok -> clear_subscriptions(state)
      {:error, :reaper_unavailable} -> notify_subscriptions(state, reason)
    end
  end

  defp terminal_dependency_failed?(state) do
    not Process.alive?(state.reaper) or not Process.alive?(state.generation_supervisor)
  end

  defp clear_subscriptions(state) do
    Enum.each(state.subscriptions, fn {_ref, entry} ->
      Process.demonitor(entry.monitor, [:flush])
    end)

    %{state | subscriptions: %{}, subscription_monitors: %{}}
  end

  defp notify_subscriptions(%{subscriptions: subscriptions} = state, _reason)
       when map_size(subscriptions) == 0 do
    state
  end

  defp notify_subscriptions(state, reason) do
    occurred_at = UPnP.Clock.utc_now(state.clock)

    Enum.each(state.subscriptions, fn {ref, entry} ->
      event =
        case entry.kind do
          :eventing ->
            %Lifecycle{
              kind: :lost,
              reason: {:control_point, reason},
              occurred_at: occurred_at
            }

          _kind ->
            %Closed{reason: reason, occurred_at: occurred_at}
        end

      send(entry.pid, {:upnp, ref, event})
      Process.demonitor(entry.monitor, [:flush])
    end)

    %{state | subscriptions: %{}, subscription_monitors: %{}}
  end

  defp remove_subscription(state, ref, demonitor? \\ true) do
    case Map.pop(state.subscriptions, ref) do
      {nil, _subscriptions} ->
        state

      {entry, subscriptions} ->
        if demonitor?, do: Process.demonitor(entry.monitor, [:flush])

        %{
          state
          | subscriptions: subscriptions,
            subscription_monitors: Map.delete(state.subscription_monitors, entry.monitor)
        }
    end
  end
end
