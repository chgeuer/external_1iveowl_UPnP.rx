defmodule UPnP.ControlPoint.Reaper do
  @moduledoc false

  use GenServer

  alias UPnP.{Clock, Eventing.Lifecycle, Subscription.Closed}
  alias UPnP.ControlPoint.Runtime

  @call_timeout 1_000

  @spec start(pid(), Runtime.id(), pid(), Clock.t()) :: GenServer.on_start()
  def start(owner, id, generation_supervisor, clock)
      when is_pid(owner) and is_reference(id) and is_pid(generation_supervisor) do
    GenServer.start(__MODULE__, {owner, id, generation_supervisor, clock})
  end

  @doc false
  @spec track_subscription(pid(), reference(), atom(), pid()) ::
          :ok | {:error, :reaper_unavailable}
  def track_subscription(reaper, ref, kind, subscriber) do
    request(reaper, {:track_subscription, ref, kind, subscriber})
  end

  @doc false
  @spec untrack_subscription(pid(), reference()) :: :ok
  def untrack_subscription(reaper, ref) do
    case request(reaper, {:untrack_subscription, ref}) do
      :ok -> :ok
      {:error, :reaper_unavailable} -> :ok
    end
  end

  @doc false
  @spec close_subscriptions(pid(), atom()) :: :ok | {:error, :reaper_unavailable}
  def close_subscriptions(reaper, reason) do
    close_subscriptions(reaper, :all, reason)
  end

  @doc false
  @spec close_subscriptions(pid(), :all | [reference()], atom()) ::
          :ok | {:error, :reaper_unavailable}
  def close_subscriptions(reaper, refs, reason) do
    request(reaper, {:close_subscriptions, refs, reason})
  end

  defp request(reaper, request) do
    GenServer.call(reaper, request, @call_timeout)
  catch
    :exit, {:timeout, _call} ->
      Process.exit(reaper, :kill)
      {:error, :reaper_unavailable}

    :exit, _reason ->
      {:error, :reaper_unavailable}
  end

  @doc false
  @spec terminate_generation(pid(), Runtime.id(), boolean()) :: :ok
  def terminate_generation(supervisor, id, false) do
    Supervisor.stop(supervisor, :shutdown, 5_000)
  catch
    :exit, _reason -> force_terminate_generation(supervisor, id)
  end

  def terminate_generation(supervisor, id, true) do
    force_terminate_generation(supervisor, id)
  end

  @doc false
  @spec terminate_runtime(Runtime.id(), [pid()]) :: :ok
  def terminate_runtime(id, excluded) when is_reference(id) and is_list(excluded) do
    case Runtime.whereis(id, :runtime) do
      nil -> :ok
      runtime -> terminate_runtime_tree(runtime, excluded)
    end
  end

  @impl true
  def init({owner, id, generation_supervisor, clock}) do
    owner_monitor = Process.monitor(owner)

    {:ok,
     %{
       clock: clock,
       owner: owner,
       owner_monitor: owner_monitor,
       id: id,
       generation_supervisor: generation_supervisor,
       subscriptions: %{},
       subscription_monitors: %{}
     }}
  end

  @impl true
  def handle_call({:track_subscription, ref, kind, subscriber}, _from, state) do
    monitor = Process.monitor(subscriber)
    entry = %{pid: subscriber, monitor: monitor, kind: kind}

    {:reply, :ok,
     %{
       state
       | subscriptions: Map.put(state.subscriptions, ref, entry),
         subscription_monitors: Map.put(state.subscription_monitors, monitor, ref)
     }}
  end

  def handle_call({:untrack_subscription, ref}, _from, state) do
    {:reply, :ok, remove_subscription(state, ref)}
  end

  def handle_call({:close_subscriptions, refs, reason}, _from, state) do
    reason =
      if Process.alive?(state.owner) and Process.alive?(state.generation_supervisor) do
        reason
      else
        :terminal_stop
      end

    {:reply, :ok, close_subscriptions_in_state(state, refs, reason)}
  end

  @impl true
  def handle_info(
        {:DOWN, monitor, :process, owner, _reason},
        %{owner: owner, owner_monitor: monitor} = state
      ) do
    state = close_subscriptions_in_state(state, :all, :terminal_stop)
    force_terminate_generation(state.generation_supervisor, state.id)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, monitor, :process, _subscriber, _reason}, state) do
    case state.subscription_monitors[monitor] do
      nil -> {:noreply, state}
      ref -> {:noreply, remove_subscription(state, ref, false)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp force_terminate_generation(supervisor, id) do
    terminate_runtime(id, [self(), supervisor])
    terminate_process(supervisor)
    terminate_runtime(id, [self(), supervisor])
  end

  defp terminate_process(process) do
    monitor = Process.monitor(process)
    Process.unlink(process)
    Process.exit(process, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^process, _reason} -> :ok
    end
  end

  defp terminate_runtime_tree(runtime, excluded) do
    excluded = MapSet.new(excluded)
    processes = collect_runtime_processes([runtime], MapSet.new(), excluded, runtime)

    monitors =
      Enum.map(processes, fn process ->
        {process, Process.monitor(process)}
      end)

    Enum.each(processes, &Process.exit(&1, :kill))

    Enum.each(monitors, fn {process, monitor} ->
      receive do
        {:DOWN, ^monitor, :process, ^process, _reason} -> :ok
      end
    end)
  end

  defp collect_runtime_processes([], processes, _excluded, _runtime), do: processes

  defp collect_runtime_processes([process | remaining], processes, excluded, runtime) do
    cond do
      MapSet.member?(processes, process) or MapSet.member?(excluded, process) ->
        collect_runtime_processes(remaining, processes, excluded, runtime)

      process != runtime and not runtime_descendant?(process, runtime) ->
        collect_runtime_processes(remaining, processes, excluded, runtime)

      true ->
        links =
          case Process.info(process, :links) do
            {:links, links} -> Enum.filter(links, &is_pid/1)
            nil -> []
          end

        collect_runtime_processes(
          links ++ remaining,
          MapSet.put(processes, process),
          excluded,
          runtime
        )
    end
  end

  defp runtime_descendant?(process, runtime) do
    case Process.info(process, :dictionary) do
      {:dictionary, dictionary} ->
        runtime in Keyword.get(dictionary, :"$ancestors", [])

      nil ->
        false
    end
  end

  defp close_subscriptions_in_state(state, refs, reason) do
    subscriptions =
      case refs do
        :all -> state.subscriptions
        refs -> Map.take(state.subscriptions, refs)
      end

    close_subscriptions_in_state(state, subscriptions, reason, map_size(subscriptions))
  end

  defp close_subscriptions_in_state(state, _subscriptions, _reason, 0) do
    state
  end

  defp close_subscriptions_in_state(state, subscriptions, reason, _count) do
    occurred_at = Clock.utc_now(state.clock)

    Enum.each(subscriptions, fn {ref, entry} ->
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
    end)

    Enum.reduce(Map.keys(subscriptions), state, &remove_subscription(&2, &1))
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
