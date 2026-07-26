defmodule UPnPBrowser.Browser do
  @moduledoc false

  use GenServer

  alias UPnP.{ControlPoint, Device, DescribedDevice}
  alias UPnP.Roster.Event
  alias UPnP.SSDP.SearchTarget

  @no_devices_delay 15_000
  @first_rediscovery_delay 5_000
  @rediscovery_interval 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  def child_spec(options) do
    options
    |> super()
    |> Map.put(:restart, :transient)
  end

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(browser \\ __MODULE__), do: GenServer.call(browser, :snapshot)

  @spec rediscover(GenServer.server()) :: :ok | {:error, term()}
  def rediscover(browser \\ __MODULE__), do: GenServer.call(browser, :rediscover)

  @impl true
  def init(options) do
    control_point = Keyword.fetch!(options, :control_point)
    addresses = Keyword.fetch!(options, :addresses)

    print_banner(addresses)

    with {:ok, subscription, devices} <- ControlPoint.subscribe_roster(control_point),
         :ok <- ControlPoint.search(control_point, target: SearchTarget.root_device()) do
      state = %{
        control_point: control_point,
        addresses: addresses,
        subscription: subscription,
        roster: Map.new(devices, &{Device.identity(&1), &1}),
        pending: %{},
        pending_keys: MapSet.new(),
        descriptions: %{},
        errors: %{},
        no_devices_timer: Process.send_after(self(), :no_devices, @no_devices_delay),
        rediscovery_timer:
          Process.send_after(self(), :scheduled_rediscovery, @first_rediscovery_delay)
      }

      state = Enum.reduce(devices, state, &start_description/2)

      if Keyword.get(options, :input, true) do
        start_input_reader(self())
      end

      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    snapshot = %{
      interfaces: state.addresses,
      roster: state.roster |> Map.values() |> Enum.sort_by(&Device.identity/1),
      descriptions:
        state.descriptions
        |> Map.values()
        |> Enum.sort_by(&description_sort_key/1),
      description_errors: state.errors,
      pending_descriptions: map_size(state.pending)
    }

    {:reply, snapshot, state}
  end

  def handle_call(:rediscover, _from, state) do
    result =
      ControlPoint.search(
        state.control_point,
        target: SearchTarget.root_device()
      )

    {:reply, result, state}
  end

  @impl true
  def handle_info(
        {:upnp, subscription_ref, %Event{} = event},
        %{subscription: %{ref: subscription_ref}} = state
      ) do
    key = Device.identity(event.device)

    case event.kind do
      kind when kind in [:appeared, :updated] ->
        state = put_in(state.roster[key], event.device)
        {:noreply, start_description(event.device, state)}

      kind when kind in [:left, :expired] ->
        {:noreply, %{state | roster: Map.delete(state.roster, key)}}
    end
  end

  def handle_info({task_ref, result}, state) when is_reference(task_ref) do
    case Map.pop(state.pending, task_ref) do
      {nil, _pending} ->
        {:noreply, state}

      {%{key: key}, pending} ->
        Process.demonitor(task_ref, [:flush])

        state = %{
          state
          | pending: pending,
            pending_keys: MapSet.delete(state.pending_keys, key)
        }

        {:noreply, finish_description(state, key, result)}
    end
  end

  def handle_info({:DOWN, task_ref, :process, _pid, reason}, state) do
    case Map.pop(state.pending, task_ref) do
      {nil, _pending} ->
        {:noreply, state}

      {%{key: key}, pending} ->
        state = %{
          state
          | pending: pending,
            pending_keys: MapSet.delete(state.pending_keys, key),
            errors: Map.put(state.errors, key, {:task_exit, reason})
        }

        {:noreply, state}
    end
  end

  def handle_info(:no_devices, state) do
    if map_size(state.descriptions) == 0 do
      IO.puts("""
      Nothing answered in 15 seconds. Things to check:
        - Running inside Docker/WSL/a devcontainer? Multicast usually does not work there;
          run this sample on the host.
        - Is a VPN active? Try disconnecting.
        - Some networks block SSDP (AP isolation or IGMP snooping).
      Still listening - devices announce themselves periodically...
      """)
    end

    {:noreply, %{state | no_devices_timer: nil}}
  end

  def handle_info(:scheduled_rediscovery, state) do
    _result =
      ControlPoint.search(
        state.control_point,
        target: SearchTarget.root_device()
      )

    timer =
      Process.send_after(
        self(),
        :scheduled_rediscovery,
        @rediscovery_interval
      )

    {:noreply, %{state | rediscovery_timer: timer}}
  end

  def handle_info(:stop_requested, state) do
    count = map_size(state.descriptions)
    IO.puts("#{count} device(s) found.")
    state = cancel_timers(state)
    UPnP.Subscription.close(state.subscription)
    ControlPoint.close(state.control_point)
    System.stop(0)
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _state = cancel_timers(state)
    UPnP.Subscription.close(state.subscription)
    ControlPoint.close(state.control_point)
    :ok
  end

  defp start_description(device, state) do
    key = Device.boot_identity(device)

    cond do
      MapSet.member?(state.pending_keys, key) ->
        state

      Enum.any?(state.descriptions, fn {_key, described} ->
        Device.boot_identity(described.device) == key
      end) ->
        state

      true ->
        task =
          Task.Supervisor.async_nolink(
            UPnPBrowser.TaskSupervisor,
            fn -> ControlPoint.describe(state.control_point, device) end
          )

        %{
          state
          | pending: Map.put(state.pending, task.ref, %{key: key}),
            pending_keys: MapSet.put(state.pending_keys, key)
        }
    end
  end

  defp finish_description(state, device_key, {:ok, %DescribedDevice{} = described}) do
    key = description_key(described)

    if not Map.has_key?(state.descriptions, key) do
      IO.write(UPnP.Samples.DeviceTree.render(described.description))
    end

    %{
      state
      | descriptions: Map.put(state.descriptions, key, described),
        errors: Map.delete(state.errors, device_key)
    }
  end

  defp finish_description(state, device_key, {:error, reason}) do
    %{state | errors: Map.put(state.errors, device_key, reason)}
  end

  defp description_key(described) do
    {
      described.description.location && URI.to_string(described.description.location),
      described.description.udn || Device.identity(described.device)
    }
  end

  defp description_sort_key(described) do
    {
      described.description.friendly_name || "",
      described.description.location && URI.to_string(described.description.location)
    }
  end

  defp print_banner(addresses) do
    formatted = Enum.map_join(addresses, ", ", &UPnP.Samples.Interfaces.format/1)

    IO.puts("UPnP network browser")
    IO.puts("Browsing from: #{formatted}")
    IO.puts("Discovering (press Enter to stop)...")
    IO.puts("")
  end

  defp start_input_reader(browser) do
    Task.Supervisor.start_child(UPnPBrowser.TaskSupervisor, fn ->
      case IO.gets("") do
        line when is_binary(line) -> send(browser, :stop_requested)
        _eof -> :ok
      end
    end)
  end

  defp cancel_timers(state) do
    if state.no_devices_timer, do: Process.cancel_timer(state.no_devices_timer)
    if state.rediscovery_timer, do: Process.cancel_timer(state.rediscovery_timer)
    %{state | no_devices_timer: nil, rediscovery_timer: nil}
  end
end
