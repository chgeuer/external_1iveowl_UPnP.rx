defmodule UpnpExplorer.Explorer do
  @moduledoc """
  Projects the UPnP roster and announcement streams into bounded UI state.
  """

  use GenServer

  alias UPnP.{ActionResult, Announcement, ControlPoint, Device, Service, Subscription}
  alias UPnP.Roster.Event
  alias UPnP.SSDP.SearchTarget
  alias UpnpExplorer.{Activity, DeviceView, ServiceView}

  @topic "upnp:explorer"
  @activity_limit 200

  @type snapshot :: %{
          devices: [DeviceView.t()],
          activities: [Activity.t()],
          status: map()
        }

  @doc "Starts the explorer projection."
  def start_link(options) do
    {name, options} = Keyword.pop(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @doc "Subscribes the caller to device, activity, and status updates."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(UpnpExplorer.PubSub, @topic)

  @doc "Returns the complete bounded UI snapshot."
  @spec snapshot(GenServer.server()) :: snapshot()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @doc "Returns filtered devices sorted by their human-readable name."
  @spec list_devices(binary(), GenServer.server()) :: [DeviceView.t()]
  def list_devices(filter \\ "", server \\ __MODULE__) do
    GenServer.call(server, {:list_devices, filter})
  end

  @doc "Returns one projected device."
  @spec get_device(binary(), GenServer.server()) :: {:ok, DeviceView.t()} | {:error, :not_found}
  def get_device(id, server \\ __MODULE__), do: GenServer.call(server, {:get_device, id})

  @doc "Returns a bounded activity feed."
  @spec list_activity(:changes | :wire | :all, GenServer.server()) :: [Activity.t()]
  def list_activity(mode \\ :changes, server \\ __MODULE__) do
    GenServer.call(server, {:list_activity, mode})
  end

  @doc "Sends one root-device M-SEARCH without resetting current state."
  @spec probe(GenServer.server()) :: :ok | {:error, term()}
  def probe(server \\ __MODULE__), do: GenServer.call(server, :probe, :infinity)

  @doc "Returns the raw service client and its projected summary."
  @spec service(binary(), binary(), GenServer.server()) ::
          {:ok, {UPnP.Service.t(), ServiceView.t()}} | {:error, :not_found}
  def service(device_id, service_id, server \\ __MODULE__) do
    GenServer.call(server, {:service, device_id, service_id})
  end

  @doc "Loads an SCPD-backed detail for one service."
  @spec service_detail(binary(), binary(), GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def service_detail(device_id, service_id, server \\ __MODULE__) do
    with {:ok, {service, summary}} <- service(device_id, service_id, server) do
      ServiceView.detail(service, summary)
    end
  end

  @doc "Runs an explicitly allowlisted read-only service action."
  @spec invoke_read_only_action(binary(), binary(), binary(), GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def invoke_read_only_action(device_id, service_id, action_name, server \\ __MODULE__) do
    with {:ok, {service, summary}} <- service(device_id, service_id, server),
         %{result_label: result_label} <- ServiceView.read_only_query(summary, action_name),
         {:ok, result} <- Service.invoke(service, action_name),
         {:ok, value} <- read_only_action_value(result, action_name) do
      {:ok, %{action_name: action_name, label: result_label, value: value}}
    else
      nil -> {:error, {:action_not_allowed, action_name}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def init(options) do
    control_point = Keyword.get(options, :control_point)

    state = %{
      control_point: control_point,
      roster_subscription: nil,
      announcement_subscription: nil,
      devices: %{},
      pending: %{},
      pending_devices: %{},
      activities: [],
      activity_sequence: 0,
      started_at: DateTime.utc_now(),
      last_activity_at: nil,
      runtime_error: nil
    }

    if control_point do
      connect(state)
    else
      {:ok, %{state | runtime_error: :network_disabled}}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       devices: sorted_devices(state.devices),
       activities: state.activities,
       status: status(state)
     }, state}
  end

  def handle_call({:list_devices, filter}, _from, state) do
    devices =
      state.devices
      |> sorted_devices()
      |> Enum.filter(&DeviceView.matches?(&1, filter))

    {:reply, devices, state}
  end

  def handle_call({:get_device, id}, _from, state) do
    reply =
      case state.devices[id] do
        nil -> {:error, :not_found}
        entry -> {:ok, entry.view}
      end

    {:reply, reply, state}
  end

  def handle_call({:list_activity, mode}, _from, state) do
    {:reply, Enum.filter(state.activities, &Activity.matches?(&1, mode)), state}
  end

  def handle_call({:service, device_id, service_id}, _from, state) do
    reply =
      with %{services: services, view: view} <- state.devices[device_id],
           %UPnP.Service{} = service <- services[service_id],
           %ServiceView{} = summary <- Enum.find(view.services, &(&1.id == service_id)) do
        {:ok, {service, summary}}
      else
        _value -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call(:probe, _from, %{control_point: nil} = state) do
    {:reply, {:error, :network_unavailable}, state}
  end

  def handle_call(:probe, _from, state) do
    result =
      ControlPoint.search(
        state.control_point,
        target: SearchTarget.root_device()
      )

    {tone, detail} =
      case result do
        :ok -> {:accent, "Listening for root-device responses"}
        {:error, reason} -> {:error, format_reason(reason)}
      end

    state =
      add_activity(
        state,
        :system,
        :search,
        "Manual network search",
        DateTime.utc_now(),
        detail: detail,
        tone: tone
      )

    {:reply, result, state}
  end

  @impl true
  def handle_info(
        {:upnp, ref, %Event{} = event},
        %{roster_subscription: %{ref: ref}} = state
      ) do
    state =
      case event.kind do
        kind when kind in [:appeared, :updated] -> put_device(state, event.device, kind)
        kind when kind in [:left, :expired] -> remove_device(state, event.device, kind)
      end

    {:noreply, state}
  end

  def handle_info(
        {:upnp, ref, %Announcement{} = announcement},
        %{announcement_subscription: %{ref: ref}} = state
      ) do
    {:noreply, add_wire_activity(state, announcement)}
  end

  def handle_info({task_ref, result}, state) when is_reference(task_ref) do
    case Map.pop(state.pending, task_ref) do
      {nil, _pending} ->
        {:noreply, state}

      {entry, pending} ->
        Process.demonitor(task_ref, [:flush])
        state = %{state | pending: pending}
        {:noreply, finish_description(state, task_ref, entry, result)}
    end
  end

  def handle_info({:DOWN, task_ref, :process, _pid, reason}, state) do
    case Map.pop(state.pending, task_ref) do
      {nil, _pending} ->
        {:noreply, state}

      {entry, pending} ->
        state = %{state | pending: pending}

        state =
          if reason == :normal do
            state
          else
            fail_description(state, task_ref, entry, {:task_exit, reason})
          end

        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_subscription(state.roster_subscription)
    close_subscription(state.announcement_subscription)
    :ok
  end

  defp connect(state) do
    with {:ok, roster_subscription, devices} <-
           ControlPoint.subscribe_roster(state.control_point),
         {:ok, announcement_subscription} <-
           ControlPoint.subscribe_announcements(state.control_point) do
      state = %{
        state
        | roster_subscription: roster_subscription,
          announcement_subscription: announcement_subscription
      }

      state = Enum.reduce(devices, state, &put_device(&2, &1, :appeared))
      {:ok, _result, state} = initial_search(state)
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp initial_search(state) do
    result =
      ControlPoint.search(
        state.control_point,
        target: SearchTarget.root_device()
      )

    state =
      case result do
        :ok ->
          add_activity(
            state,
            :system,
            :search,
            "Explorer started listening",
            DateTime.utc_now(),
            detail: "Root-device search sent",
            tone: :accent
          )

        {:error, reason} ->
          state
          |> Map.put(:runtime_error, reason)
          |> add_activity(
            :system,
            :search_failed,
            "Initial network search failed",
            DateTime.utc_now(),
            detail: format_reason(reason),
            tone: :error
          )
      end

    {:ok, result, state}
  end

  defp put_device(state, device, kind) do
    id = DeviceView.id(device)
    generation = generation(device)
    existing = state.devices[id]

    {entry, state} =
      if existing && existing.generation == generation && existing.described do
        described = %{existing.described | device: device}
        {view, services} = DeviceView.from_described(described)

        {%{existing | device: device, described: described, view: view, services: services},
         state}
      else
        partial =
          case existing do
            nil ->
              DeviceView.from_discovered(device)

            %{view: view} ->
              %{
                view
                | boot_id: device.boot_id,
                  config_id: device.config_id,
                  max_age: device.max_age,
                  last_seen_at: DateTime.utc_now(),
                  status: :describing,
                  description_error: nil
              }
          end

        entry = %{
          device: device,
          described: nil,
          generation: generation,
          view: partial,
          services: %{}
        }

        {entry, start_description(state, id, device, generation)}
      end

    state = put_in(state.devices[id], entry)
    broadcast({:explorer_device_upserted, entry.view})

    verb = if kind == :updated, do: "updated", else: "appeared"

    state
    |> add_activity(
      :change,
      kind,
      "#{entry.view.name} #{verb}",
      DateTime.utc_now(),
      device_id: id,
      detail: entry.view.location,
      tone: :accent
    )
    |> broadcast_status()
  end

  defp remove_device(state, device, kind) do
    id = DeviceView.id(device)
    {entry, devices} = Map.pop(state.devices, id)
    name = if entry, do: entry.view.name, else: "Device at #{device.location.host}"
    pending_devices = Map.delete(state.pending_devices, id)

    broadcast({:explorer_device_removed, id})

    state
    |> Map.put(:devices, devices)
    |> Map.put(:pending_devices, pending_devices)
    |> add_activity(
      :change,
      kind,
      "#{name} #{if(kind == :expired, do: "expired", else: "left")}",
      DateTime.utc_now(),
      device_id: id,
      detail: URI.to_string(device.location),
      tone: :warning
    )
    |> broadcast_status()
  end

  defp start_description(state, id, device, generation) do
    task =
      Task.Supervisor.async_nolink(
        UpnpExplorer.TaskSupervisor,
        fn -> ControlPoint.describe(state.control_point, device) end
      )

    pending_entry = %{task: task, device_id: id, generation: generation}

    %{
      state
      | pending: Map.put(state.pending, task.ref, pending_entry),
        pending_devices: Map.put(state.pending_devices, id, task.ref)
    }
  end

  defp finish_description(state, task_ref, entry, {:ok, described}) do
    if current_task?(state, task_ref, entry) do
      {view, services} = DeviceView.from_described(described)

      device_entry = %{
        device: described.device,
        described: described,
        generation: entry.generation,
        view: view,
        services: services
      }

      state =
        state
        |> put_in([:devices, entry.device_id], device_entry)
        |> update_in([:pending_devices], &Map.delete(&1, entry.device_id))

      broadcast({:explorer_device_upserted, view})

      state
      |> add_activity(
        :change,
        :described,
        "#{view.name} described",
        DateTime.utc_now(),
        device_id: view.id,
        detail: "#{view.service_count} services across #{view.embedded_count + 1} device nodes",
        tone: :success
      )
      |> broadcast_status()
    else
      state
    end
  end

  defp finish_description(state, task_ref, entry, {:error, reason}) do
    fail_description(state, task_ref, entry, reason)
  end

  defp fail_description(state, task_ref, entry, reason) do
    if current_task?(state, task_ref, entry) do
      case state.devices[entry.device_id] do
        nil ->
          state

        device_entry ->
          view = %{
            device_entry.view
            | status: :degraded,
              description_error: format_reason(reason)
          }

          state =
            state
            |> put_in([:devices, entry.device_id, :view], view)
            |> update_in([:pending_devices], &Map.delete(&1, entry.device_id))

          broadcast({:explorer_device_upserted, view})

          state
          |> add_activity(
            :change,
            :description_failed,
            "#{view.name} could not be described",
            DateTime.utc_now(),
            device_id: view.id,
            detail: view.description_error,
            tone: :warning
          )
          |> broadcast_status()
      end
    else
      state
    end
  end

  defp current_task?(state, task_ref, entry) do
    state.pending_devices[entry.device_id] == task_ref &&
      match?(
        %{generation: generation} when generation == entry.generation,
        state.devices[entry.device_id]
      )
  end

  defp add_wire_activity(state, announcement) do
    id = DeviceView.id(announcement.device)
    title = wire_title(announcement.kind)
    detail = announcement.device.usn || URI.to_string(announcement.device.location)

    case state.activities do
      [
        %Activity{
          category: :wire,
          kind: kind,
          device_id: ^id,
          title: ^title
        } = current
        | rest
      ]
      when kind == announcement.kind ->
        if DateTime.diff(announcement.received_at, current.occurred_at, :second) <= 4 do
          activity = %{
            current
            | count: current.count + 1,
              occurred_at: announcement.received_at,
              detail: detail
          }

          broadcast({:explorer_activity_upserted, activity})

          broadcast(
            {:explorer_status, status(%{state | last_activity_at: announcement.received_at})}
          )

          %{state | activities: [activity | rest], last_activity_at: announcement.received_at}
        else
          new_wire_activity(state, announcement, id, title, detail)
        end

      _activities ->
        new_wire_activity(state, announcement, id, title, detail)
    end
  end

  defp new_wire_activity(state, announcement, id, title, detail) do
    add_activity(
      state,
      :wire,
      announcement.kind,
      title,
      announcement.received_at,
      device_id: id,
      detail: detail
    )
  end

  defp add_activity(state, category, kind, title, occurred_at, options) do
    sequence = state.activity_sequence + 1
    activity = Activity.new(sequence, category, kind, title, occurred_at, options)
    activities = [activity | state.activities] |> Enum.take(@activity_limit)

    broadcast({:explorer_activity_upserted, activity})

    state = %{
      state
      | activities: activities,
        activity_sequence: sequence,
        last_activity_at: occurred_at
    }

    broadcast({:explorer_status, status(state)})
    state
  end

  defp status(state) do
    %{
      network_available?: not is_nil(state.control_point),
      device_count: map_size(state.devices),
      pending_count: map_size(state.pending_devices),
      last_activity_at: state.last_activity_at,
      started_at: state.started_at,
      runtime_error: state.runtime_error
    }
  end

  defp broadcast_status(state) do
    broadcast({:explorer_status, status(state)})
    state
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(UpnpExplorer.PubSub, @topic, message)
  end

  defp sorted_devices(devices) do
    devices
    |> Map.values()
    |> Enum.map(& &1.view)
    |> Enum.sort_by(&{String.downcase(&1.name), &1.id})
  end

  defp generation(device), do: {Device.boot_identity(device), device.config_id}

  defp read_only_action_value(result, "GetExternalIPAddress") do
    case ActionResult.get(result, "NewExternalIPAddress") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:invalid_response, :missing_external_address}}
          address -> {:ok, address}
        end

      _value ->
        {:error, {:invalid_response, :missing_external_address}}
    end
  end

  defp wire_title(:alive), do: "Alive announcement"
  defp wire_title(:byebye), do: "Byebye announcement"
  defp wire_title(:search_response), do: "Search response"

  defp close_subscription(nil), do: :ok
  defp close_subscription(subscription), do: Subscription.close(subscription)

  defp format_reason(reason) do
    case reason do
      exception when is_exception(exception) -> Exception.message(exception)
      value -> inspect(value, pretty: true, limit: 8, printable_limit: 240)
    end
  end
end
