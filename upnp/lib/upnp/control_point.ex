defmodule UPnP.ControlPoint do
  @moduledoc """
  A supervised UPnP control point.

  It owns SSDP interface workers, a bounded presence roster, local subscribers,
  and the description/SCPD caches used by higher-level APIs. The roster holds at
  most `UPnP.Options.max_roster_entries` identities (default `1_024`). Admitting
  a new identity at capacity evicts the least recently observed entry, breaking
  ties by identity. Eviction cancels that entry's timer, prunes its document
  caches, and emits an `:expired` roster change before the new `:appeared`
  change.

  Starting a control point starts a `UPnP.ControlPoint.Runtime`: an isolated
  supervision subtree holding the coordinator and every SSDP and eventing
  process belonging to it. `start_link/1` and `UPnP.start_control_point/1`
  therefore return the runtime supervisor. That handle, the coordinator pid,
  and a `:name` given at startup are interchangeable in every function here.
  """

  use GenServer

  alias UPnP.{
    Action,
    Announcement,
    Clock,
    DescribedDevice,
    Device,
    Options,
    ServiceDescription,
    Subscription
  }

  alias UPnP.ControlPoint.Runtime
  alias UPnP.Eventing.Manager, as: EventingManager
  alias UPnP.Roster.Event, as: RosterEvent
  alias UPnP.SSDP.{Envelope, Interface, SearchTarget}

  # Keep this independent of parsing because test seams and future callers can inject envelopes.
  @maximum_roster_age_seconds 86_400

  def child_spec(options) do
    %{
      id: Keyword.get(options, :name, {__MODULE__, make_ref()}),
      start: {__MODULE__, :start_link, [options]},
      type: :supervisor,
      restart: :transient,
      shutdown: :infinity
    }
  end

  @doc """
  Starts a control point runtime and returns its supervisor.

  Pass the returned pid, or the `:name` given here, to the functions in this
  module.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []), do: Runtime.start_link(options)

  @doc false
  @spec start_coordinator(keyword()) :: GenServer.on_start()
  def start_coordinator(options) do
    {name, options} = Keyword.pop(options, :name)
    genserver_options = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, options, genserver_options)
  end

  @doc """
  Resolves a control point handle to its coordinator process.

  Runtime supervisors, coordinator pids, and registered names all resolve to the
  coordinator; names that are not registered return `nil`.
  """
  @spec whereis(GenServer.server()) :: pid() | nil
  def whereis(control_point) do
    case GenServer.whereis(control_point) do
      nil ->
        nil

      pid ->
        case Runtime.identity(pid) do
          {id, :runtime} -> Runtime.whereis(id, :coordinator)
          _other -> pid
        end
    end
  end

  @doc """
  Resolves a control point handle to its runtime supervisor.

  Processes outside a runtime, and names that are not registered, return `nil`.
  """
  @spec runtime(GenServer.server()) :: pid() | nil
  def runtime(control_point) do
    case GenServer.whereis(control_point) do
      nil ->
        nil

      pid ->
        case Runtime.identity(pid) do
          {_id, :runtime} -> pid
          {id, :coordinator} -> Runtime.whereis(id, :runtime)
          _other -> nil
        end
    end
  end

  defp server(control_point) do
    whereis(control_point) || control_point
  end

  @doc """
  Subscribes a process to roster changes.

  The current roster is returned atomically with the subscription. Subsequent
  events arrive as `{:upnp, subscription.ref, %UPnP.Roster.Event{}}`.
  """
  @spec subscribe_roster(GenServer.server(), pid()) ::
          {:ok, Subscription.t(), [Device.t()]}
  def subscribe_roster(control_point, subscriber \\ self()) when is_pid(subscriber) do
    GenServer.call(server(control_point), {:subscribe, :roster, subscriber})
  end

  @doc """
  Subscribes a process to the passive, unreplayed SSDP activity feed.
  """
  @spec subscribe_announcements(GenServer.server(), pid()) ::
          {:ok, Subscription.t()}
  def subscribe_announcements(control_point, subscriber \\ self()) when is_pid(subscriber) do
    GenServer.call(server(control_point), {:subscribe, :announcements, subscriber})
  end

  @doc """
  Sends M-SEARCH and returns the devices observed during its MX window.
  """
  @spec discover(GenServer.server(), keyword()) :: {:ok, [Device.t()]} | {:error, term()}
  def discover(control_point, options \\ []) do
    GenServer.call(server(control_point), {:discover, options}, :infinity)
  end

  @doc "Sends an M-SEARCH burst without resetting roster or subscriptions."
  @spec search(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def search(control_point, options \\ []) do
    GenServer.call(server(control_point), {:search, options}, :infinity)
  end

  @doc "Returns the current roster snapshot."
  @spec roster(GenServer.server()) :: [Device.t()]
  def roster(control_point), do: GenServer.call(server(control_point), :roster)

  @doc """
  Fetches a discovered device's description through the single-flight cache.
  """
  @spec describe(GenServer.server(), Device.t()) ::
          {:ok, DescribedDevice.t()} | {:error, term()}
  def describe(control_point, %Device{} = device) do
    key = description_key(device)

    with {:ok, description} <-
           GenServer.call(
             server(control_point),
             {:get_description, key, device.location},
             :infinity
           ) do
      {:ok,
       %DescribedDevice{
         control_point: control_point,
         device: device,
         description: description
       }}
    end
  end

  @doc false
  @spec get_scpd(GenServer.server(), ServiceDescription.t(), term()) ::
          {:ok, UPnP.SCPD.t()} | {:error, term()}
  def get_scpd(control_point, %ServiceDescription{scpd_url: %URI{} = url}, cache_scope) do
    GenServer.call(
      server(control_point),
      {:get_scpd, {cache_scope, URI.to_string(url)}, url},
      :infinity
    )
  end

  def get_scpd(_control_point, %ServiceDescription{}, _cache_scope),
    do: {:error, :missing_scpd_url}

  @doc false
  @spec invoke_action(
          GenServer.server(),
          ServiceDescription.t(),
          binary(),
          UPnP.SOAP.arguments(),
          keyword()
        ) :: {:ok, UPnP.ActionResult.t()} | {:error, term()}
  def invoke_action(control_point, service, action_name, arguments, options) do
    GenServer.call(
      server(control_point),
      {:invoke_action, service, action_name, arguments, options},
      :infinity
    )
  end

  @doc """
  Gracefully closes the control point and its runtime.

  Bounded GENA cleanup runs first, then the coordinator stops normally, which
  shuts its runtime down instead of restarting it. The call returns once the
  runtime is gone; `timeout` bounds the cleanup and the shutdown separately.
  A runtime whose coordinator is already gone is torn down without inventing
  protocol goodbyes, and closing an already closed control point is `:ok`. Use
  `UPnP.stop_control_point/1` for an abrupt stop.
  """
  @spec close(GenServer.server(), timeout()) :: :ok
  def close(control_point, timeout \\ 40_000) do
    case GenServer.whereis(control_point) do
      nil -> :ok
      pid -> close_resolved(Runtime.identity(pid), pid, timeout)
    end
  end

  defp close_resolved({id, :runtime}, runtime, timeout),
    do: close_runtime(id, runtime, timeout)

  defp close_resolved({id, :coordinator}, _coordinator, timeout) do
    case Runtime.whereis(id, :runtime) do
      nil -> :ok
      runtime -> close_runtime(id, runtime, timeout)
    end
  end

  defp close_resolved(_identity, coordinator, timeout) do
    _outcome = request_close(coordinator, timeout)
    :ok
  end

  defp close_runtime(id, runtime, timeout) do
    monitor = Process.monitor(runtime)

    case close_coordinator(Runtime.whereis(id, :coordinator), timeout) do
      :ok -> :ok
      :gone -> stop_runtime(runtime, timeout)
    end

    await_shutdown(monitor, timeout)
  end

  defp close_coordinator(nil, _timeout), do: :gone
  defp close_coordinator(coordinator, timeout), do: request_close(coordinator, timeout)

  defp request_close(coordinator, timeout) do
    GenServer.call(coordinator, :close, timeout)
  catch
    :exit, {:noproc, _} -> :gone
    :exit, {:normal, _} -> :gone
    :exit, {:shutdown, _} -> :gone
    :exit, {{:shutdown, _}, _} -> :gone
  end

  defp stop_runtime(runtime, timeout) do
    Supervisor.stop(runtime, :shutdown, timeout)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
    :exit, {:shutdown, _} -> :ok
  end

  defp await_shutdown(monitor, timeout) do
    receive do
      {:DOWN, ^monitor, :process, _runtime, _reason} -> :ok
    after
      timeout ->
        Process.demonitor(monitor, [:flush])
        exit({:timeout, {__MODULE__, :close, [timeout]}})
    end
  end

  @doc false
  @spec inject(GenServer.server(), Envelope.t()) :: :ok
  def inject(control_point, %Envelope{} = envelope) do
    GenServer.cast(server(control_point), {:inject, envelope})
  end

  @doc false
  @spec options(GenServer.server()) :: Options.t()
  def options(control_point), do: GenServer.call(server(control_point), :options)

  @doc """
  Subscribes to a service event URL through this control point's shared manager.
  """
  @spec subscribe_events(GenServer.server(), URI.t(), keyword()) ::
          UPnP.Eventing.Manager.subscribe_result()
  def subscribe_events(control_point, %URI{} = event_sub_url, options \\ []) do
    with {:ok, manager} <- eventing_manager(control_point) do
      EventingManager.subscribe(manager, event_sub_url, options)
    end
  catch
    :exit, {:noproc, _reason} -> {:error, :eventing_unavailable}
    :exit, {:normal, _reason} -> {:error, :eventing_unavailable}
  end

  @doc "Returns callback-listener details after the first event subscription."
  @spec event_callback_info(GenServer.server()) ::
          {:ok, UPnP.Eventing.Manager.callback_info()} | {:error, term()}
  def event_callback_info(control_point) do
    with {:ok, manager} <- eventing_manager(control_point) do
      EventingManager.callback_info(manager)
    end
  end

  @doc false
  @spec eventing_manager(GenServer.server()) :: {:ok, pid()} | {:error, :eventing_unavailable}
  def eventing_manager(control_point),
    do: GenServer.call(server(control_point), :eventing_manager)

  @impl true
  def init(raw_options) do
    {runtime_id, raw_options} = Keyword.pop!(raw_options, :runtime_id)

    with :ok <- Runtime.register(runtime_id, :coordinator),
         {:ok, options} <- Options.new(raw_options),
         options = %{options | task_supervisor: Runtime.name(runtime_id, :tasks)},
         {:ok, addresses} <- resolve_interfaces(options.interfaces),
         {:ok, eventing, eventing_monitor} <- start_eventing(options, runtime_id) do
      state = %{
        runtime_id: runtime_id,
        options: options,
        interfaces: [],
        roster: %{},
        roster_order: :gb_trees.empty(),
        subscribers: %{roster: %{}, announcements: %{}},
        monitors: %{},
        discoveries: %{},
        description_cache: %{},
        scpd_cache: %{},
        pending: %{},
        operations: %{},
        eventing: eventing,
        eventing_monitor: eventing_monitor
      }

      {:ok, start_interfaces(state, addresses)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:subscribe, kind, subscriber}, _from, state)
      when kind in [:roster, :announcements] do
    ref = make_ref()
    monitor = Process.monitor(subscriber)
    subscription = %Subscription{server: self(), ref: ref, kind: kind}
    entry = %{pid: subscriber, monitor: monitor}
    state = put_in(state.subscribers[kind][ref], entry)
    state = put_in(state.monitors[monitor], {kind, ref})

    reply =
      case kind do
        :roster ->
          {:ok, subscription, Enum.map(state.roster, fn {_key, entry} -> entry.device end)}

        :announcements ->
          {:ok, subscription}
      end

    {:reply, reply, state}
  end

  def handle_call({:unsubscribe, ref}, _from, state) do
    {:reply, :ok, remove_subscription(state, ref)}
  end

  def handle_call({:discover, call_options}, from, state) do
    case discovery_options(state.options, call_options) do
      {:ok, target, search_options} ->
        case send_search(state, target, search_options) do
          :ok ->
            discovery_ref = make_ref()
            timeout = search_options[:mx] * 1_000 + 250

            timer =
              Clock.send_after(
                state.options.clock,
                self(),
                {:discovery_complete, discovery_ref},
                timeout
              )

            discovery = %{
              from: from,
              target: target,
              devices: %{},
              timer: timer
            }

            {:noreply, put_in(state.discoveries[discovery_ref], discovery)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:search, call_options}, _from, state) do
    with {:ok, target, search_options} <- discovery_options(state.options, call_options) do
      {:reply, send_search(state, target, search_options), state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:roster, _from, state) do
    {:reply, Enum.map(state.roster, fn {_key, entry} -> entry.device end), state}
  end

  def handle_call({:get_description, key, location}, from, state) do
    cached_call(
      state,
      :description,
      key,
      from,
      fn -> UPnP.Description.Client.fetch(location, state.options) end
    )
  end

  def handle_call({:get_scpd, key, location}, from, state) do
    cached_call(
      state,
      :scpd,
      key,
      from,
      fn -> UPnP.SCPD.Client.fetch(location, state.options) end
    )
  end

  def handle_call({:invoke_action, service, action_name, arguments, options}, from, state) do
    start_operation(
      state,
      {:call, from},
      fn -> Action.invoke(service, action_name, arguments, state.options, options) end
    )
  end

  def handle_call(:options, _from, state), do: {:reply, state.options, state}

  def handle_call(:eventing_manager, _from, %{eventing: eventing} = state)
      when is_pid(eventing) do
    if Process.alive?(eventing) do
      {:reply, {:ok, eventing}, state}
    else
      {:reply, {:error, :eventing_unavailable}, state}
    end
  end

  def handle_call(:eventing_manager, _from, state),
    do: {:reply, {:error, :eventing_unavailable}, state}

  def handle_call(:close, _from, state) do
    if state.eventing && Process.alive?(state.eventing) do
      EventingManager.close(state.eventing)
    end

    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_cast({:inject, envelope}, state) do
    {:noreply, handle_envelope(envelope, state)}
  end

  @impl true
  def handle_info({:ssdp, _interface, envelope}, state) do
    {:noreply, handle_envelope(envelope, state)}
  end

  def handle_info({:discovery_complete, discovery_ref}, state) do
    case Map.pop(state.discoveries, discovery_ref) do
      {nil, _discoveries} ->
        {:noreply, state}

      {discovery, discoveries} ->
        GenServer.reply(discovery.from, {:ok, Map.values(discovery.devices)})
        {:noreply, %{state | discoveries: discoveries}}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.get(state.operations, ref) do
      nil ->
        {:noreply, state}

      _operation ->
        Process.demonitor(ref, [:flush])
        {:noreply, finish_operation(state, ref, result)}
    end
  end

  def handle_info({:expire, key, seen_at}, state) do
    case state.roster[key] do
      %{seen_at: ^seen_at} ->
        {:noreply, remove_roster_entry(state, key, :expired)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    cond do
      Map.has_key?(state.operations, monitor) ->
        {:noreply, finish_operation(state, monitor, {:error, {:task_exit, reason}})}

      state.eventing_monitor == monitor ->
        {:stop, {:eventing_manager_exit, reason}, %{state | eventing: nil, eventing_monitor: nil}}

      Map.has_key?(state.monitors, monitor) ->
        {_kind, ref} = state.monitors[monitor]
        {:noreply, remove_subscription(state, ref)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:interface_failed, address, reason}, state) do
    UPnP.Telemetry.emit([:upnp, :ssdp, :interface_error], %{}, %{
      interface: address,
      reason: reason
    })

    {:noreply, state}
  end

  defp handle_envelope(%Envelope{kind: :byebye} = envelope, state) do
    state = broadcast_announcement(envelope, state)

    case key_from_usn(envelope.usn) do
      nil ->
        state

      key ->
        remove_roster_entry(state, key, :left)
    end
  end

  defp handle_envelope(%Envelope{location: nil}, state), do: state

  defp handle_envelope(envelope, state) do
    device = to_device(envelope)
    state = broadcast_announcement(envelope, state, device)
    state = collect_discoveries(envelope, device, state)
    update_roster(device, state)
  end

  defp update_roster(device, state) do
    key = Device.identity(device)
    now = Clock.monotonic_time(state.options.clock)
    state = evict_for_admission(state, key)

    max_age_seconds =
      min(
        device.max_age || div(state.options.roster_expiry_fallback, 1_000),
        @maximum_roster_age_seconds
      )

    max_age_ms = max_age_seconds * 1_000

    expiry_timer =
      Clock.send_after(state.options.clock, self(), {:expire, key, now}, max_age_ms)

    {event_kind, state} =
      case state.roster[key] do
        nil ->
          {:appeared, state}

        previous ->
          Clock.cancel_timer(state.options.clock, previous.expiry_timer)
          state = remove_roster_order(state, key, previous)

          if previous.device.boot_id != device.boot_id or
               previous.device.config_id != device.config_id do
            {:updated, prune_document_caches(state, device.location)}
          else
            {nil, state}
          end
      end

    entry = %{device: device, seen_at: now, expiry_timer: expiry_timer}

    state = %{
      state
      | roster: Map.put(state.roster, key, entry),
        roster_order: :gb_trees.enter({now, key}, key, state.roster_order)
    }

    if event_kind do
      broadcast_roster(state, event_kind, device)
    end

    state
  end

  defp evict_for_admission(state, key) do
    if not Map.has_key?(state.roster, key) and
         map_size(state.roster) >= state.options.max_roster_entries do
      {{_seen_at, oldest_key}, _value} = :gb_trees.smallest(state.roster_order)

      remove_roster_entry(state, oldest_key, :expired)
    else
      state
    end
  end

  defp remove_roster_entry(state, key, event_kind) do
    case Map.pop(state.roster, key) do
      {nil, _roster} ->
        state

      {entry, roster} ->
        Clock.cancel_timer(state.options.clock, entry.expiry_timer)
        state = %{remove_roster_order(state, key, entry) | roster: roster}
        state = prune_document_caches(state, entry.device.location)
        broadcast_roster(state, event_kind, entry.device)
        state
    end
  end

  defp remove_roster_order(state, key, entry) do
    %{state | roster_order: :gb_trees.delete_any({entry.seen_at, key}, state.roster_order)}
  end

  defp collect_discoveries(envelope, device, state) do
    discoveries =
      Map.new(state.discoveries, fn {ref, discovery} ->
        if target_matches?(discovery.target, envelope) do
          key = Device.boot_identity(device)
          {ref, put_in(discovery.devices[key], device)}
        else
          {ref, discovery}
        end
      end)

    %{state | discoveries: discoveries}
  end

  defp target_matches?(%SearchTarget{value: "ssdp:all"}, _envelope), do: true

  defp target_matches?(%SearchTarget{value: target}, envelope) do
    Enum.any?([envelope.search_target, envelope.notification_type], fn value ->
      is_binary(value) and String.downcase(value) == String.downcase(target)
    end)
  end

  defp broadcast_announcement(envelope, state, device \\ nil)

  defp broadcast_announcement(envelope, state, device) do
    device =
      device ||
        case envelope.location do
          nil ->
            key = key_from_usn(envelope.usn)
            state.roster[key] && state.roster[key].device

          _ ->
            to_device(envelope)
        end

    if device do
      announcement = %Announcement{
        kind: envelope.kind,
        device: device,
        received_at: Clock.utc_now(state.options.clock)
      }

      broadcast(state.subscribers.announcements, announcement)
    end

    state
  end

  defp broadcast(subscribers, event) do
    Enum.each(subscribers, fn {ref, %{pid: pid}} -> send(pid, {:upnp, ref, event}) end)
  end

  defp broadcast_roster(state, kind, device) do
    UPnP.Telemetry.emit([:upnp, :roster, :change], %{}, %{
      kind: kind,
      identity: Device.identity(device)
    })

    broadcast(state.subscribers.roster, %RosterEvent{kind: kind, device: device})
  end

  defp to_device(envelope) do
    %Device{
      location: envelope.location,
      usn: envelope.usn,
      server: envelope.server,
      boot_id: envelope.boot_id,
      config_id: envelope.config_id,
      max_age: envelope.max_age,
      local_address: envelope.local_address,
      remote_endpoint: envelope.remote_endpoint,
      parsing_error?: envelope.parsing_error?
    }
  end

  defp key_from_usn(nil), do: nil

  defp key_from_usn(usn) do
    usn |> String.split("::", parts: 2) |> hd() |> String.downcase()
  end

  defp discovery_options(options, call_options) do
    target = Keyword.get(call_options, :target, options.default_search_target)
    mx = Keyword.get(call_options, :mx, options.default_mx)

    cond do
      not match?(%SearchTarget{}, target) ->
        {:error, :invalid_search_target}

      mx not in 1..5 ->
        {:error, :invalid_mx}

      true ->
        {:ok, target,
         [
           mx: mx,
           friendly_name: options.friendly_name,
           repetitions: options.search_repetitions,
           repeat_interval: options.search_repeat_interval
         ]}
    end
  end

  defp send_search(%{interfaces: []}, _target, _options), do: :ok

  defp send_search(state, target, options) do
    results = Enum.map(state.interfaces, &Interface.search(&1, target, options))

    if Enum.all?(results, &match?({:error, _}, &1)) do
      {:error, {:all_interfaces_failed, results}}
    else
      :ok
    end
  end

  defp start_interfaces(state, addresses) do
    interfaces =
      Enum.flat_map(addresses, fn address ->
        options = [
          coordinator: self(),
          address: address,
          transport: state.options.udp_transport,
          clock: state.options.clock
        ]

        case DynamicSupervisor.start_child(
               Runtime.name(state.runtime_id, :ssdp_interfaces),
               {Interface, options}
             ) do
          {:ok, pid} ->
            [pid]

          {:error, reason} ->
            send(self(), {:interface_failed, address, reason})
            []
        end
      end)

    %{state | interfaces: interfaces}
  end

  defp resolve_interfaces(:auto) do
    with {:ok, interfaces} <- :inet.getifaddrs() do
      addresses =
        interfaces
        |> Enum.flat_map(fn {_name, properties} ->
          flags = Keyword.get(properties, :flags, [])

          if :up in flags and :multicast in flags and :loopback not in flags do
            properties
            |> Keyword.get_values(:addr)
            |> Enum.filter(&ipv4?/1)
          else
            []
          end
        end)
        |> Enum.uniq()

      {:ok, addresses}
    end
  end

  defp resolve_interfaces(addresses) when is_list(addresses), do: {:ok, addresses}

  defp ipv4?({_, _, _, _}), do: true
  defp ipv4?(_address), do: false

  defp start_eventing(options, runtime_id) do
    manager_options = [
      owner: self(),
      control_point: self(),
      clock: options.clock,
      transport: options.event_transport,
      http_adapter: options.http_adapter,
      network_adapter: options.network_adapter,
      task_supervisor: options.task_supervisor,
      subscription_supervisor: Runtime.name(runtime_id, :eventing_subscriptions),
      server_supervisor: Runtime.name(runtime_id, :eventing_servers),
      callback_bind: options.event_callback_bind,
      callback_port: options.event_callback_port,
      callback_host: options.event_callback_host,
      callback_base_url: options.event_callback_base_url,
      callback_acceptors: options.event_callback_acceptors,
      subscription_timeout: options.event_subscription_timeout,
      operation_timeout: options.action_timeout,
      retry_backoff: options.event_retry_backoff,
      max_callback_body_bytes: options.max_event_body_bytes,
      auto_resubscribe: options.auto_resubscribe
    ]

    child_spec =
      Supervisor.child_spec(
        {EventingManager, manager_options},
        restart: :temporary
      )

    case DynamicSupervisor.start_child(
           Runtime.name(runtime_id, :eventing_managers),
           child_spec
         ) do
      {:ok, manager} -> {:ok, manager, Process.monitor(manager)}
      {:error, reason} -> {:error, {:eventing_start_failed, reason}}
    end
  end

  defp cached_call(state, kind, key, from, function) do
    cache = Map.fetch!(state, cache_field(kind))
    pending_key = {kind, key}

    case Map.fetch(cache, key) do
      {:ok, value} ->
        {:reply, {:ok, value}, state}

      :error ->
        case state.pending[pending_key] do
          nil ->
            case start_operation(state, {:cached, kind, key}, function) do
              {:noreply, state} ->
                pending = Map.put(state.pending, pending_key, [from])
                {:noreply, %{state | pending: pending}}
            end

          waiters ->
            pending = Map.put(state.pending, pending_key, [from | waiters])
            {:noreply, %{state | pending: pending}}
        end
    end
  end

  defp start_operation(state, operation, function) do
    task = Task.Supervisor.async_nolink(state.options.task_supervisor, function)
    operations = Map.put(state.operations, task.ref, %{operation: operation, task: task})
    {:noreply, %{state | operations: operations}}
  end

  defp finish_operation(state, ref, result) do
    {entry, operations} = Map.pop(state.operations, ref)
    state = %{state | operations: operations}

    case entry.operation do
      {:call, from} ->
        GenServer.reply(from, result)
        state

      {:cached, kind, key} ->
        pending_key = {kind, key}
        {waiters, pending} = Map.pop(state.pending, pending_key, [])
        Enum.each(waiters, &GenServer.reply(&1, result))
        state = %{state | pending: pending}

        case result do
          {:ok, value} ->
            cache_field = cache_field(kind)
            Map.update!(state, cache_field, &Map.put(&1, key, value))

          {:error, _reason} ->
            state
        end
    end
  end

  defp cache_field(:description), do: :description_cache
  defp cache_field(:scpd), do: :scpd_cache

  defp description_key(%Device{} = device) do
    {URI.to_string(device.location), device.config_id, device.boot_id}
  end

  defp prune_document_caches(state, location) do
    location = URI.to_string(location)

    description_cache =
      Map.reject(state.description_cache, fn
        {{^location, _config_id, _boot_id}, _description} -> true
        {_key, _description} -> false
      end)

    scpd_cache =
      Map.reject(state.scpd_cache, fn
        {{{^location, _config_id, _boot_id}, _scpd_url}, _scpd} -> true
        {_key, _scpd} -> false
      end)

    %{state | description_cache: description_cache, scpd_cache: scpd_cache}
  end

  defp remove_subscription(state, ref) do
    Enum.reduce([:roster, :announcements], state, fn kind, acc ->
      case Map.pop(acc.subscribers[kind], ref) do
        {nil, _subscribers} ->
          acc

        {%{monitor: monitor}, subscribers} ->
          Process.demonitor(monitor, [:flush])
          acc = put_in(acc.subscribers[kind], subscribers)
          %{acc | monitors: Map.delete(acc.monitors, monitor)}
      end
    end)
  end

  @impl true
  def terminate(_reason, state) do
    if state.eventing && Process.alive?(state.eventing) do
      EventingManager.stop(state.eventing)
    end

    Enum.each(state.operations, fn {_ref, %{task: task}} ->
      Task.shutdown(task, :brutal_kill)
    end)

    :ok
  end
end
