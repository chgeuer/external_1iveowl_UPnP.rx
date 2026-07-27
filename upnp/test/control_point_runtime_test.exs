defmodule UPnP.ControlPoint.RuntimeTest do
  use ExUnit.Case, async: true

  alias UPnP.Clock.Manual
  alias UPnP.ControlPoint
  alias UPnP.ControlPoint.Owner
  alias UPnP.ControlPoint.Runtime
  alias UPnP.SSDP.SearchTarget

  defmodule Named do
  end

  defmodule RecoveringNamed do
  end

  defmodule FakeTransport do
    @behaviour UPnP.SSDP.Transport

    @impl true
    def open({test, gate}, address, options) do
      worker = self()

      {attempt, block?} =
        Agent.get_and_update(gate, fn state ->
          attempt = state.opens + 1
          block? = attempt == Map.get(state, :block_on_open)
          {{attempt, block?}, %{state | opens: attempt, blocked: if(block?, do: worker)}}
        end)

      Kernel.send(test, {:opening, self(), attempt, address})
      if block?, do: await_gate(:open, attempt)
      open(test, address, options)
    end

    def open(test, address, _options) do
      socket = make_ref()
      send(test, {:opened, self(), socket, address})
      {:ok, socket}
    end

    @impl true
    def activate({test, _gate}, socket), do: activate(test, socket)
    def activate(_test, _socket), do: :ok

    @impl true
    def send({test, gate}, socket, address, port, payload) do
      worker = self()

      {attempt, block?} =
        Agent.get_and_update(gate, fn state ->
          attempt = Map.get(state, :sends, 0) + 1
          block? = attempt == Map.get(state, :block_on_send)

          {{attempt, block?},
           Map.merge(state, %{sends: attempt, blocked: if(block?, do: worker)})}
        end)

      Kernel.send(test, {:sending, self(), attempt})
      if block?, do: await_gate(:send, attempt)
      send(test, socket, address, port, payload)
    end

    def send(test, socket, address, port, payload) do
      Kernel.send(test, {:sent, socket, address, port, IO.iodata_to_binary(payload)})
      :ok
    end

    @impl true
    def close({test, _gate}, socket), do: close(test, socket)

    def close(test, socket) do
      Kernel.send(test, {:closed, socket})
      :ok
    end

    defp await_gate(kind, attempt) do
      receive do
        {:continue, ^kind, ^attempt} -> :ok
      end
    end
  end

  setup do
    {:ok, clock} = start_supervised(Manual)
    %{clock: clock}
  end

  test "invalid owner options fail before registering the public name" do
    Process.flag(:trap_exit, true)

    assert {:error, :invalid_interfaces} =
             ControlPoint.start_link(name: FailedStartup, interfaces: :invalid)

    assert Process.whereis(FailedStartup) == nil
  end

  test "stale lifecycle messages cannot mutate the active generation", %{clock: clock} do
    address = {192, 0, 2, 43}
    control_point = start_control_point(clock, address)
    assert_receive {:opened, _interface, _socket, ^address}

    state = :sys.get_state(control_point)
    coordinator = state.coordinator
    runtime = state.runtime

    send(
      control_point,
      {:control_point_coordinator_started, make_ref(), runtime, coordinator}
    )

    send(control_point, {:control_point_runtime_started, make_ref(), runtime})
    send(control_point, {:runtime_start_result, make_ref(), {:error, :stale}})
    send(control_point, {:coordinator_healthy, make_ref(), coordinator})
    send(control_point, {:recover_runtime, make_ref()})
    send(control_point, {:DOWN, make_ref(), :process, self(), :normal})
    send(control_point, {:EXIT, self(), :normal})
    send(state.reaper, :unexpected)

    assert %{coordinator: ^coordinator, runtime: ^runtime} = :sys.get_state(control_point)
    assert is_map(:sys.get_state(state.reaper))
    assert ControlPoint.roster(control_point) == []
  end

  test "an interface failure domain stays inside its own control point", %{clock: clock} do
    first = start_control_point(clock, {192, 0, 2, 10})
    second = start_control_point(clock, {192, 0, 2, 20})

    assert_receive {:opened, first_interface, _socket, {192, 0, 2, 10}}
    assert_receive {:opened, second_interface, _socket, {192, 0, 2, 20}}

    second_monitor = Process.monitor(second_interface)

    first_interface
    |> crash_repeatedly({192, 0, 2, 10}, 3)
    |> Process.exit(:kill)

    refute_receive {:DOWN, ^second_monitor, :process, ^second_interface, _reason}, 500
    assert Process.alive?(second_interface)
    assert ControlPoint.roster(second) == []

    assert_receive {:opened, recovered, _socket, {192, 0, 2, 10}}
    refute recovered == first_interface
    assert ControlPoint.roster(first) == []
  end

  test "an owned supervisor crash restarts one runtime and spares the other", %{clock: clock} do
    first = start_control_point(clock, {192, 0, 2, 11})
    second = start_control_point(clock, {192, 0, 2, 21})

    assert_receive {:opened, first_interface, _socket, {192, 0, 2, 11}}
    assert_receive {:opened, second_interface, _socket, {192, 0, 2, 21}}

    {first_id, :owner} = Runtime.identity(first)
    first_coordinator = ControlPoint.whereis(first)
    second_coordinator = ControlPoint.whereis(second)
    interfaces = Runtime.whereis(first_id, :ssdp_interfaces)
    interface_monitor = Process.monitor(first_interface)
    second_monitor = Process.monitor(second_interface)

    Process.exit(interfaces, :kill)

    assert_receive {:DOWN, ^interface_monitor, :process, ^first_interface, _reason}
    assert_receive {:opened, recovered, _socket, {192, 0, 2, 11}}

    refute recovered == first_interface
    refute ControlPoint.whereis(first) == first_coordinator
    refute Process.alive?(first_coordinator)

    refute_receive {:DOWN, ^second_monitor, :process, ^second_interface, _reason}, 200
    assert ControlPoint.whereis(second) == second_coordinator
    assert Process.alive?(second_interface)
  end

  test "a coordinator crash restarts the runtime without orphaned descendants", %{clock: clock} do
    control_point = start_control_point(clock, {192, 0, 2, 12})
    assert_receive {:opened, interface, _socket, {192, 0, 2, 12}}

    coordinator = ControlPoint.whereis(control_point)
    assert {:ok, manager} = ControlPoint.eventing_manager(control_point)

    interface_monitor = Process.monitor(interface)
    manager_monitor = Process.monitor(manager)

    Process.exit(coordinator, :kill)

    assert_receive {:DOWN, ^interface_monitor, :process, ^interface, _reason}
    assert_receive {:DOWN, ^manager_monitor, :process, ^manager, _reason}
    assert_receive {:opened, recovered, _socket, {192, 0, 2, 12}}

    refute recovered == interface
    assert Process.alive?(control_point)
    refute ControlPoint.whereis(control_point) == coordinator
    await_ready(control_point)
    assert ControlPoint.roster(control_point) == []
  end

  test "a coordinator restart closes local subscriptions with a typed reason", %{clock: clock} do
    address = {192, 0, 2, 24}
    control_point = start_control_point(clock, address)
    assert_receive {:opened, _interface, _socket, ^address}

    assert {:ok, roster, []} = ControlPoint.subscribe_roster(control_point)
    assert {:ok, announcements} = ControlPoint.subscribe_announcements(control_point)

    coordinator = ControlPoint.whereis(control_point)
    Process.exit(coordinator, :kill)

    assert_receive {:opened, _recovered, _socket, ^address}
    await_ready(control_point)

    roster_ref = roster.ref
    announcements_ref = announcements.ref

    assert_receive {:upnp, ^roster_ref,
                    %{
                      __struct__: UPnP.Subscription.Closed,
                      reason: :internal_restart
                    }}

    assert_receive {:upnp, ^announcements_ref,
                    %{
                      __struct__: UPnP.Subscription.Closed,
                      reason: :internal_restart
                    }}

    assert {:ok, _replacement, []} = ControlPoint.subscribe_roster(control_point)
  end

  test "a stale startup message cannot replace the live coordinator", %{clock: clock} do
    address = {192, 0, 2, 34}
    control_point = start_control_point(clock, address)
    assert_receive {:opened, _interface, _socket, ^address}

    {id, :owner} = Runtime.identity(control_point)
    runtime = Runtime.whereis(id, :runtime)
    stale = ControlPoint.whereis(control_point)

    Process.exit(stale, :kill)
    assert_receive {:opened, _replacement_interface, _socket, ^address}
    await_ready(control_point)

    replacement = ControlPoint.whereis(control_point)
    assert replacement != stale
    assert {:ok, subscription, []} = ControlPoint.subscribe_roster(control_point)

    send(
      control_point,
      {:control_point_coordinator_started, id, runtime, stale}
    )

    assert :sys.get_state(control_point).coordinator == replacement
    assert ControlPoint.roster(control_point) == []
    subscription_ref = subscription.ref
    refute_receive {:upnp, ^subscription_ref, %UPnP.Subscription.Closed{}}
  end

  test "a crash storm exhausts one generation then recovers the stable handle", %{clock: clock} do
    address = {192, 0, 2, 25}

    control_point =
      start_supervised!(
        {ControlPoint,
         name: RecoveringNamed,
         interfaces: [address],
         clock: {Manual, clock},
         udp_transport: {FakeTransport, self()}},
        id: {:control_point, address}
      )

    assert_receive {:opened, _interface, _socket, ^address}
    stable_monitor = Process.monitor(control_point)

    exhaust_runtime_generation(control_point, address)

    assert ControlPoint.roster(control_point) == {:error, :control_point_restarting}
    assert ControlPoint.search(control_point) == {:error, :control_point_restarting}
    assert ControlPoint.discover(control_point) == {:error, :control_point_restarting}

    assert ControlPoint.subscribe_roster(control_point) ==
             {:error, :control_point_restarting}

    assert ControlPoint.inject(control_point, %UPnP.SSDP.Envelope{kind: :alive}) ==
             {:error, :control_point_restarting}

    assert ControlPoint.options(control_point) == {:error, :control_point_restarting}
    assert ControlPoint.eventing_manager(control_point) == {:error, :control_point_restarting}
    assert UPnP.IGD.discover_gateway(control_point) == {:error, :control_point_restarting}
    assert Process.whereis(RecoveringNamed) == control_point
    assert ControlPoint.roster(RecoveringNamed) == {:error, :control_point_restarting}
    assert Process.alive?(control_point)
    refute_receive {:DOWN, ^stable_monitor, :process, ^control_point, _reason}

    assert clock |> :sys.get_state() |> Map.fetch!(:timers) |> map_size() == 1

    :ok = Manual.advance(clock, 999)
    assert ControlPoint.roster(control_point) == {:error, :control_point_restarting}

    :ok = Manual.advance(clock, 1)
    assert_receive {:opened, recovered, _socket, ^address}
    assert is_pid(recovered)
    await_ready(control_point)
    assert ControlPoint.roster(control_point) == []
    assert ControlPoint.roster(RecoveringNamed) == []
  end

  test "calls fail immediately while a recovery generation is still starting", %{clock: clock} do
    address = {192, 0, 2, 28}

    gate =
      start_supervised!(
        {Agent, fn -> %{opens: 0, sends: 0, block_on_open: 7, blocked: nil} end},
        id: :recovery_start_gate
      )

    on_exit(fn ->
      if Process.alive?(gate) do
        case Agent.get(gate, & &1.blocked) do
          pid when is_pid(pid) -> send(pid, {:continue, :open, 7})
          nil -> :ok
        end
      end
    end)

    control_point =
      start_supervised!(
        {ControlPoint,
         interfaces: [address],
         clock: {Manual, clock},
         udp_transport: {FakeTransport, {self(), gate}}},
        id: {:control_point, address}
      )

    assert_receive {:opened, _interface, _socket, ^address}
    exhaust_runtime_generation(control_point, address)
    :ok = Manual.advance(clock, 1_000)
    assert_receive {:opening, starter, 7, ^address}
    assert ControlPoint.whereis(control_point) == nil

    test = self()

    spawn(fn ->
      send(test, {:roster_during_recovery, ControlPoint.roster(control_point)})
    end)

    assert_receive {:roster_during_recovery, {:error, :control_point_restarting}}

    send(starter, {:continue, :open, 7})
    assert_receive {:opened, _interface, _socket, ^address}
    await_ready(control_point)
    assert ControlPoint.roster(control_point) == []
  end

  test "closing while a recovery generation is starting terminates the whole tree", %{
    clock: clock
  } do
    address = {192, 0, 2, 31}

    gate =
      start_supervised!(
        {Agent, fn -> %{opens: 0, sends: 0, block_on_open: 7, blocked: nil} end},
        id: :graceful_close_start_gate
      )

    on_exit(fn -> release_blocked_open(gate, 7) end)

    control_point =
      start_supervised!(
        {ControlPoint,
         interfaces: [address],
         clock: {Manual, clock},
         udp_transport: {FakeTransport, {self(), gate}}},
        id: {:control_point, address}
      )

    assert_receive {:opened, _interface, _socket, ^address}
    exhaust_runtime_generation(control_point, address)
    :ok = Manual.advance(clock, 1_000)
    assert_receive {:opening, starter, 7, ^address}

    {id, :owner} = Runtime.identity(control_point)
    generations = Runtime.whereis(id, :generations)
    runtime = Runtime.whereis(id, :runtime)
    owner_monitor = Process.monitor(control_point)
    generations_monitor = Process.monitor(generations)
    runtime_monitor = Process.monitor(runtime)
    starter_monitor = Process.monitor(starter)

    assert ControlPoint.close(control_point, 1_000) == :ok

    assert_receive {:DOWN, ^owner_monitor, :process, ^control_point, _reason}, 1_000
    assert_receive {:DOWN, ^generations_monitor, :process, ^generations, _reason}, 1_000
    assert_receive {:DOWN, ^runtime_monitor, :process, ^runtime, _reason}, 1_000
    assert_receive {:DOWN, ^starter_monitor, :process, ^starter, _reason}, 1_000
  end

  test "abrupt stop during recovery startup leaves no orphaned generation", %{clock: clock} do
    address = {192, 0, 2, 32}

    gate =
      start_supervised!(
        {Agent, fn -> %{opens: 0, sends: 0, block_on_open: 7, blocked: nil} end},
        id: :abrupt_stop_start_gate
      )

    on_exit(fn -> release_blocked_open(gate, 7) end)

    assert {:ok, control_point} =
             UPnP.start_control_point(
               interfaces: [address],
               clock: {Manual, clock},
               udp_transport: {FakeTransport, {self(), gate}}
             )

    on_exit(fn ->
      if Process.alive?(control_point), do: UPnP.stop_control_point(control_point)
    end)

    assert_receive {:opened, _interface, _socket, ^address}
    exhaust_runtime_generation(control_point, address)
    :ok = Manual.advance(clock, 1_000)
    assert_receive {:opening, starter, 7, ^address}

    {id, :owner} = Runtime.identity(control_point)
    generations = Runtime.whereis(id, :generations)
    runtime = Runtime.whereis(id, :runtime)

    on_exit(fn ->
      if Process.alive?(generations), do: Process.exit(generations, :kill)
    end)

    owner_monitor = Process.monitor(control_point)
    generations_monitor = Process.monitor(generations)
    runtime_monitor = Process.monitor(runtime)
    starter_monitor = Process.monitor(starter)

    assert UPnP.stop_control_point(control_point) == :ok

    assert_receive {:DOWN, ^owner_monitor, :process, ^control_point, _reason}, 1_000
    assert_receive {:DOWN, ^generations_monitor, :process, ^generations, _reason}, 1_000
    assert_receive {:DOWN, ^runtime_monitor, :process, ^runtime, _reason}, 1_000
    assert_receive {:DOWN, ^starter_monitor, :process, ^starter, _reason}, 1_000
  end

  test "an untrappable owner exit reaps a blocked recovery generation", %{clock: clock} do
    address = {192, 0, 2, 35}

    gate =
      start_supervised!(
        {Agent, fn -> %{opens: 0, sends: 0, block_on_open: 7, blocked: nil} end},
        id: :killed_owner_start_gate
      )

    on_exit(fn -> release_blocked_open(gate, 7) end)

    control_point =
      start_supervised!(%{
        id: {:control_point, address},
        start:
          {ControlPoint, :start_link,
           [
             [
               interfaces: [address],
               clock: {Manual, clock},
               udp_transport: {FakeTransport, {self(), gate}}
             ]
           ]},
        restart: :temporary,
        shutdown: :infinity,
        type: :worker
      })

    assert_receive {:opened, _interface, _socket, ^address}
    exhaust_runtime_generation(control_point, address)
    :ok = Manual.advance(clock, 1_000)
    assert_receive {:opening, interface, 7, ^address}

    {id, :owner} = Runtime.identity(control_point)
    generations = Runtime.whereis(id, :generations)
    runtime = Runtime.whereis(id, :runtime)
    %{runtime_start: {_token, worker, _monitor}} = :sys.get_state(control_point)

    on_exit(fn ->
      Enum.each([interface, worker, runtime, generations], fn process ->
        if Process.alive?(process), do: Process.exit(process, :kill)
      end)
    end)

    owner_monitor = Process.monitor(control_point)
    generations_monitor = Process.monitor(generations)
    runtime_monitor = Process.monitor(runtime)
    worker_monitor = Process.monitor(worker)
    interface_monitor = Process.monitor(interface)

    Process.exit(control_point, :kill)

    assert_receive {:DOWN, ^owner_monitor, :process, ^control_point, :killed}, 1_000
    assert_receive {:DOWN, ^generations_monitor, :process, ^generations, _reason}, 1_000
    assert_receive {:DOWN, ^runtime_monitor, :process, ^runtime, _reason}, 1_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 1_000
    assert_receive {:DOWN, ^interface_monitor, :process, ^interface, _reason}, 1_000
  end

  test "an untrappable owner exit closes subscriptions with a terminal reason", %{clock: clock} do
    address = {192, 0, 2, 36}

    control_point =
      start_supervised!(%{
        id: {:control_point, address},
        start:
          {ControlPoint, :start_link,
           [
             [
               interfaces: [address],
               clock: {Manual, clock},
               udp_transport: {FakeTransport, self()}
             ]
           ]},
        restart: :temporary,
        shutdown: :infinity,
        type: :worker
      })

    assert_receive {:opened, _interface, _socket, ^address}
    assert {:ok, roster, []} = ControlPoint.subscribe_roster(control_point)
    assert {:ok, announcements} = ControlPoint.subscribe_announcements(control_point)

    Process.exit(control_point, :kill)

    roster_ref = roster.ref
    announcements_ref = announcements.ref

    assert_receive {:upnp, ^roster_ref, %UPnP.Subscription.Closed{reason: :terminal_stop}}

    assert_receive {:upnp, ^announcements_ref, %UPnP.Subscription.Closed{reason: :terminal_stop}}
  end

  @tag capture_log: true
  test "reaper loss stops the owner and uses its terminal-event fallback", %{clock: clock} do
    address = {192, 0, 2, 37}

    control_point =
      start_supervised!(%{
        id: {:control_point, address},
        start:
          {ControlPoint, :start_link,
           [
             [
               interfaces: [address],
               clock: {Manual, clock},
               udp_transport: {FakeTransport, self()}
             ]
           ]},
        restart: :temporary,
        shutdown: :infinity,
        type: :worker
      })

    assert_receive {:opened, _interface, _socket, ^address}
    assert {:ok, subscription, []} = ControlPoint.subscribe_roster(control_point)

    %{reaper: reaper} = :sys.get_state(control_point)
    owner_monitor = Process.monitor(control_point)
    Process.exit(reaper, :kill)

    subscription_ref = subscription.ref

    assert_receive {:upnp, ^subscription_ref, %UPnP.Subscription.Closed{reason: :terminal_stop}}

    assert_receive {:DOWN, ^owner_monitor, :process, ^control_point, _reason}, 1_000
  end

  @tag capture_log: true
  test "queued terminal dependency loss outranks an internal restart", %{clock: clock} do
    address = {192, 0, 2, 38}

    control_point =
      start_supervised!(%{
        id: {:control_point, address},
        start:
          {ControlPoint, :start_link,
           [
             [
               interfaces: [address],
               clock: {Manual, clock},
               udp_transport: {FakeTransport, self()}
             ]
           ]},
        restart: :temporary,
        shutdown: :infinity,
        type: :worker
      })

    assert_receive {:opened, _interface, _socket, ^address}
    assert {:ok, subscription, []} = ControlPoint.subscribe_roster(control_point)

    %{coordinator: coordinator, reaper: reaper} = :sys.get_state(control_point)
    coordinator_monitor = Process.monitor(coordinator)
    reaper_monitor = Process.monitor(reaper)
    :ok = :sys.suspend(control_point)

    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :killed}, 1_000

    Process.exit(reaper, :kill)
    assert_receive {:DOWN, ^reaper_monitor, :process, ^reaper, :killed}, 1_000
    :ok = :sys.resume(control_point)

    subscription_ref = subscription.ref

    assert_receive {:upnp, ^subscription_ref, %UPnP.Subscription.Closed{reason: :terminal_stop}}

    refute_receive {:upnp, ^subscription_ref,
                    %UPnP.Subscription.Closed{reason: :internal_restart}}
  end

  @tag capture_log: true
  test "a timed-out reaper request cannot emit a duplicate terminal event", %{clock: clock} do
    address = {192, 0, 2, 39}

    control_point =
      start_supervised!(%{
        id: {:control_point, address},
        start:
          {ControlPoint, :start_link,
           [
             [
               interfaces: [address],
               clock: {Manual, clock},
               udp_transport: {FakeTransport, self()}
             ]
           ]},
        restart: :temporary,
        shutdown: :infinity,
        type: :worker
      })

    assert_receive {:opened, _interface, _socket, ^address}
    assert {:ok, subscription, []} = ControlPoint.subscribe_roster(control_point)

    %{coordinator: coordinator, reaper: reaper} = :sys.get_state(control_point)

    on_exit(fn ->
      if Process.alive?(reaper), do: :sys.resume(reaper)
    end)

    reaper_monitor = Process.monitor(reaper)
    :ok = :sys.suspend(reaper)
    Process.exit(coordinator, :kill)

    assert_receive {:DOWN, ^reaper_monitor, :process, ^reaper, :killed}, 2_000

    subscription_ref = subscription.ref

    assert_receive {:upnp, ^subscription_ref, %UPnP.Subscription.Closed{reason: :terminal_stop}},
                   2_000

    refute_receive {:upnp, ^subscription_ref, %UPnP.Subscription.Closed{}}, 200
  end

  test "a queued reaper request promotes owner loss to a terminal event", %{clock: clock} do
    address = {192, 0, 2, 40}

    control_point =
      start_supervised!(%{
        id: {:control_point, address},
        start:
          {ControlPoint, :start_link,
           [
             [
               interfaces: [address],
               clock: {Manual, clock},
               udp_transport: {FakeTransport, self()}
             ]
           ]},
        restart: :temporary,
        shutdown: :infinity,
        type: :worker
      })

    assert_receive {:opened, _interface, _socket, ^address}
    assert {:ok, subscription, []} = ControlPoint.subscribe_roster(control_point)

    %{coordinator: coordinator, reaper: reaper} = :sys.get_state(control_point)

    on_exit(fn ->
      if Process.alive?(reaper), do: :sys.resume(reaper)
    end)

    coordinator_monitor = Process.monitor(coordinator)
    owner_monitor = Process.monitor(control_point)
    :ok = :sys.suspend(reaper)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :killed}, 1_000
    await_queued_message(reaper)

    Process.exit(control_point, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^control_point, :killed}, 1_000
    :ok = :sys.resume(reaper)

    subscription_ref = subscription.ref

    assert_receive {:upnp, ^subscription_ref, %UPnP.Subscription.Closed{reason: :terminal_stop}},
                   1_000

    refute_receive {:upnp, ^subscription_ref,
                    %UPnP.Subscription.Closed{reason: :internal_restart}}
  end

  @tag capture_log: true
  test "a recovery generation stays private until its monitored starter succeeds", %{
    clock: clock
  } do
    address = {192, 0, 2, 33}

    gate =
      start_supervised!(
        {Agent, fn -> %{opens: 0, sends: 0, block_on_open: 7, blocked: nil} end},
        id: :failed_recovery_starter_gate
      )

    on_exit(fn -> release_blocked_open(gate, 7) end)

    control_point =
      start_supervised!(
        {ControlPoint,
         interfaces: [address],
         clock: {Manual, clock},
         udp_transport: {FakeTransport, {self(), gate}}},
        id: {:control_point, address}
      )

    assert_receive {:opened, _interface, _socket, ^address}
    exhaust_runtime_generation(control_point, address)
    :ok = Manual.advance(clock, 1_000)
    assert_receive {:opening, starter, 7, ^address}

    %{runtime_start: {_token, worker, _monitor}, runtime: runtime} =
      :sys.get_state(control_point)

    on_exit(fn ->
      if Process.alive?(worker), do: :erlang.resume_process(worker)
    end)

    true = :erlang.suspend_process(worker)
    send(starter, {:continue, :open, 7})
    assert_receive {:opened, ^starter, _socket, ^address}

    {id, :owner} = Runtime.identity(control_point)
    coordinator = await_runtime_component(id, :coordinator)

    send(
      control_point,
      {:control_point_coordinator_started, id, runtime, coordinator}
    )

    owner_state = :sys.get_state(control_point)
    assert owner_state.runtime_start != nil
    assert owner_state.coordinator == nil
    assert ControlPoint.whereis(control_point) == nil

    assert ControlPoint.subscribe_roster(control_point) ==
             {:error, :control_point_restarting}

    runtime_monitor = Process.monitor(runtime)
    starter_monitor = Process.monitor(starter)
    Process.exit(worker, :kill)

    assert_receive {:DOWN, ^runtime_monitor, :process, ^runtime, _reason}, 1_000
    assert_receive {:DOWN, ^starter_monitor, :process, ^starter, _reason}, 1_000
    assert Process.alive?(control_point)
    assert ControlPoint.roster(control_point) == {:error, :control_point_restarting}
    assert only_timer_delay(clock) == 2_000

    :ok = Manual.advance(clock, 2_000)
    assert_receive {:opened, _interface, _socket, ^address}
    await_ready(control_point)
    assert ControlPoint.roster(control_point) == []
  end

  test "an arbitrary coordinator exit becomes tagged availability data", %{clock: clock} do
    address = {192, 0, 2, 29}
    control_point = start_control_point(clock, address)
    assert_receive {:opened, _interface, socket, ^address}
    coordinator = ControlPoint.whereis(control_point)
    test = self()

    caller =
      spawn(fn ->
        result = ControlPoint.discover(control_point, mx: 1)
        send(test, {:discover_result, self(), result})
      end)

    assert_receive {:sent, ^socket, {239, 255, 255, 250}, 1900, _payload}
    Process.exit(coordinator, :boom)

    assert_receive {:discover_result, ^caller, {:error, :control_point_restarting}}
    assert Process.alive?(control_point)
  end

  test "generation recovery backoff escalates and resets after sixty healthy seconds", %{
    clock: clock
  } do
    address = {192, 0, 2, 27}
    control_point = start_control_point(clock, address)
    assert_receive {:opened, _interface, _socket, ^address}

    exhaust_runtime_generation(control_point, address)
    assert only_timer_delay(clock) == 1_000
    :ok = Manual.advance(clock, 1_000)
    assert_receive {:opened, _interface, _socket, ^address}
    await_ready(control_point)
    assert ControlPoint.roster(control_point) == []

    exhaust_runtime_generation(control_point, address)
    assert only_timer_delay(clock) == 2_000
    :ok = Manual.advance(clock, 2_000)
    assert_receive {:opened, _interface, _socket, ^address}
    await_ready(control_point)
    assert ControlPoint.roster(control_point) == []

    :ok = Manual.advance(clock, 60_000)
    owner_state = :sys.get_state(control_point)
    assert owner_state.backoff_index == 0
    assert owner_state.timer == nil

    exhaust_runtime_generation(control_point, address)
    assert only_timer_delay(clock) == 1_000
  end

  test "healthy time restarts when the coordinator generation changes", %{clock: clock} do
    address = {192, 0, 2, 30}
    control_point = start_control_point(clock, address)
    assert_receive {:opened, _interface, _socket, ^address}

    exhaust_runtime_generation(control_point, address)
    :ok = Manual.advance(clock, 1_000)
    assert_receive {:opened, _interface, _socket, ^address}
    await_ready(control_point)
    assert ControlPoint.roster(control_point) == []

    :ok = Manual.advance(clock, 59_000)
    crash_coordinator_and_wait(control_point, address)
    assert ControlPoint.roster(control_point) == []

    :ok = Manual.advance(clock, 1_000)
    assert :sys.get_state(control_point).backoff_index == 1

    :ok = Manual.advance(clock, 59_000)
    assert :sys.get_state(control_point).backoff_index == 0
  end

  test "search resolves the replacement interface after a transient worker restart", %{
    clock: clock
  } do
    address = {192, 0, 2, 26}
    control_point = start_control_point(clock, address)
    assert_receive {:opened, interface, _socket, ^address}
    coordinator = ControlPoint.whereis(control_point)
    coordinator_monitor = Process.monitor(coordinator)

    Process.exit(interface, :kill)
    assert_receive {:opened, replacement, socket, ^address}
    refute replacement == interface

    assert :ok = ControlPoint.search(control_point)
    assert_receive {:sent, ^socket, {239, 255, 255, 250}, 1900, _payload}
    refute_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, _reason}
  end

  test "an interface exit during search cannot crash the coordinator", %{clock: clock} do
    address = {192, 0, 2, 31}

    gate =
      start_supervised!(
        {Agent, fn -> %{opens: 0, sends: 0, block_on_send: 1, blocked: nil} end},
        id: :search_send_gate
      )

    control_point =
      start_supervised!(
        {ControlPoint,
         interfaces: [address],
         clock: {Manual, clock},
         udp_transport: {FakeTransport, {self(), gate}}},
        id: {:control_point, address}
      )

    assert_receive {:opened, interface, _socket, ^address}
    coordinator = ControlPoint.whereis(control_point)
    coordinator_monitor = Process.monitor(coordinator)
    test = self()

    spawn(fn -> send(test, {:search_result, ControlPoint.search(control_point)}) end)
    assert_receive {:sending, ^interface, 1}
    Process.exit(interface, :kill)

    assert_receive {:search_result,
                    {:error, {:all_interfaces_failed, [{:error, :interface_restarting}]}}}

    refute_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, _reason}
    assert_receive {:opened, replacement, _socket, ^address}
    refute replacement == interface
  end

  test "the runtime owns the coordinator, its interfaces, and its eventing", %{clock: clock} do
    control_point = start_control_point(clock, {192, 0, 2, 13})
    assert_receive {:opened, interface, _socket, {192, 0, 2, 13}}

    coordinator = ControlPoint.whereis(control_point)
    assert {:ok, manager} = ControlPoint.eventing_manager(control_point)
    assert {id, :owner} = Runtime.identity(control_point)

    assert Runtime.whereis(id, :coordinator) == coordinator
    assert Runtime.identity(coordinator) == {id, :coordinator}
    assert ControlPoint.runtime(coordinator) == control_point
    assert ControlPoint.runtime(control_point) == control_point

    components = [
      :owner,
      :generations,
      :runtime,
      :coordinator,
      :tasks,
      :ssdp_interfaces,
      :eventing_managers,
      :eventing_subscriptions,
      :eventing_servers
    ]

    Enum.each(components, fn component ->
      handle = Runtime.whereis(id, component)
      monitor = Process.monitor(handle)
      assert ControlPoint.whereis(handle) == coordinator
      assert ControlPoint.runtime(handle) == control_point
      assert ControlPoint.roster(handle) == []
      assert Process.alive?(handle)
      refute_receive {:DOWN, ^monitor, :process, ^handle, _reason}
      Process.demonitor(monitor, [:flush])
    end)

    assert children(Runtime.whereis(id, :ssdp_interfaces)) == [interface]
    assert children(Runtime.whereis(id, :eventing_managers)) == [manager]
    assert is_pid(Runtime.whereis(id, :tasks))
    assert is_pid(Runtime.whereis(id, :eventing_subscriptions))
    assert is_pid(Runtime.whereis(id, :eventing_servers))

    assert ControlPoint.options(control_point).task_supervisor ==
             Runtime.name(id, :tasks)
  end

  test "a public name resolves through the registry to the coordinator", %{clock: clock} do
    control_point =
      start_supervised!(
        {ControlPoint,
         name: Named,
         interfaces: [],
         clock: {Manual, clock},
         udp_transport: {FakeTransport, self()}}
      )

    assert ControlPoint.whereis(Named) == ControlPoint.whereis(control_point)
    assert ControlPoint.runtime(Named) == control_point
    assert ControlPoint.roster(Named) == []
    assert ControlPoint.whereis(UPnP.ControlPoint.RuntimeTest.Missing) == nil
    assert ControlPoint.runtime(UPnP.ControlPoint.RuntimeTest.Missing) == nil
  end

  test "public search dispatches through the interface and validates options", %{clock: clock} do
    control_point = start_control_point(clock, {192, 0, 2, 23})
    assert_receive {:opened, _interface, socket, {192, 0, 2, 23}}

    assert ControlPoint.search(control_point) == :ok
    assert_receive {:sent, ^socket, {239, 255, 255, 250}, 1900, default_payload}
    assert default_payload =~ "ST: upnp:rootdevice\r\n"

    assert ControlPoint.search(control_point, target: SearchTarget.all(), mx: 1) == :ok
    assert_receive {:sent, ^socket, {239, 255, 255, 250}, 1900, payload}
    assert payload =~ "ST: ssdp:all\r\n"

    assert ControlPoint.search(control_point, target: :invalid) ==
             {:error, :invalid_search_target}

    assert ControlPoint.search(control_point, mx: 0) == {:error, :invalid_mx}

    discovery = Task.async(fn -> ControlPoint.discover(control_point) end)
    assert_receive {:sent, ^socket, {239, 255, 255, 250}, 1900, discovery_payload}
    assert discovery_payload =~ "ST: upnp:rootdevice\r\n"
    _options = ControlPoint.options(control_point)
    :ok = Manual.advance(clock, 3_250)
    assert Task.await(discovery) == {:ok, []}
  end

  test "a graceful close stops every owned process and is idempotent", %{clock: clock} do
    control_point = start_control_point(clock, {192, 0, 2, 14})
    assert_receive {:opened, interface, socket, {192, 0, 2, 14}}

    coordinator = ControlPoint.whereis(control_point)
    assert {:ok, manager} = ControlPoint.eventing_manager(control_point)
    assert {:ok, local_subscription, []} = ControlPoint.subscribe_roster(control_point)
    {id, :owner} = Runtime.identity(control_point)
    tasks = Runtime.whereis(id, :tasks)

    runtime_monitor = Process.monitor(control_point)
    coordinator_monitor = Process.monitor(coordinator)
    manager_monitor = Process.monitor(manager)
    interface_monitor = Process.monitor(interface)
    task_monitor = Process.monitor(tasks)

    assert :ok = ControlPoint.close(control_point)

    refute Process.alive?(control_point)
    refute Process.alive?(coordinator)

    assert_receive {:DOWN, ^runtime_monitor, :process, ^control_point, :shutdown}
    assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, _reason}
    assert_receive {:DOWN, ^manager_monitor, :process, ^manager, _reason}
    assert_receive {:DOWN, ^interface_monitor, :process, ^interface, _reason}
    assert_receive {:DOWN, ^task_monitor, :process, ^tasks, _reason}
    assert_receive {:closed, ^socket}

    assert_receive {:upnp, ref, %UPnP.Subscription.Closed{reason: :graceful_close}}

    assert ref == local_subscription.ref

    refute_receive {:opened, _interface, _socket, {192, 0, 2, 14}}, 200
    refute Enum.any?([manager, interface, tasks], &Process.alive?/1)
    refute alive?(ControlPoint.whereis(control_point))
    assert :ok = ControlPoint.close(control_point)
  end

  test "an abrupt stop terminates the whole runtime subtree", %{clock: clock} do
    assert {:ok, control_point} =
             UPnP.start_control_point(
               interfaces: [{192, 0, 2, 15}],
               clock: {Manual, clock},
               udp_transport: {FakeTransport, self()}
             )

    on_exit(fn -> UPnP.stop_control_point(control_point) end)
    assert_receive {:opened, interface, _socket, {192, 0, 2, 15}}

    coordinator = ControlPoint.whereis(control_point)
    assert {:ok, manager} = ControlPoint.eventing_manager(control_point)
    assert {:ok, local_subscription, []} = ControlPoint.subscribe_roster(control_point)

    runtime_monitor = Process.monitor(control_point)
    interface_monitor = Process.monitor(interface)
    manager_monitor = Process.monitor(manager)

    assert :ok = UPnP.stop_control_point(coordinator)

    assert_receive {:DOWN, ^runtime_monitor, :process, ^control_point, _reason}
    assert_receive {:DOWN, ^interface_monitor, :process, ^interface, _reason}
    assert_receive {:DOWN, ^manager_monitor, :process, ^manager, _reason}

    assert_receive {:upnp, ref, %UPnP.Subscription.Closed{reason: :terminal_stop}}
    assert ref == local_subscription.ref

    refute Process.alive?(coordinator)
    assert UPnP.stop_control_point(control_point) == {:error, :not_found}
  end

  test "a directly supervised control point is not a child of the application", %{clock: clock} do
    control_point = start_control_point(clock, {192, 0, 2, 16})

    assert UPnP.stop_control_point(control_point) == {:error, :not_found}
    assert Process.alive?(control_point)
  end

  test "a directly supervised control point takes its runtime down with its owner", %{
    clock: clock
  } do
    owner =
      start_supervised!(%{
        id: :owner_supervisor,
        type: :supervisor,
        restart: :temporary,
        start:
          {Supervisor, :start_link,
           [
             [
               {ControlPoint,
                interfaces: [{192, 0, 2, 17}],
                clock: {Manual, clock},
                udp_transport: {FakeTransport, self()}}
             ],
             [strategy: :one_for_one]
           ]}
      })

    assert_receive {:opened, interface, socket, {192, 0, 2, 17}}
    [{_id, control_point, :worker, _modules}] = Supervisor.which_children(owner)

    coordinator = ControlPoint.whereis(control_point)
    assert {:ok, manager} = ControlPoint.eventing_manager(control_point)
    {id, :owner} = Runtime.identity(control_point)
    interfaces = Runtime.whereis(id, :ssdp_interfaces)
    managers = Runtime.whereis(id, :eventing_managers)

    coordinator_monitor = Process.monitor(coordinator)
    manager_monitor = Process.monitor(manager)
    interface_monitor = Process.monitor(interface)

    Supervisor.stop(owner, :shutdown)

    assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, _reason}
    assert_receive {:DOWN, ^manager_monitor, :process, ^manager, _reason}
    assert_receive {:DOWN, ^interface_monitor, :process, ^interface, _reason}
    assert_receive {:closed, ^socket}

    refute Process.alive?(control_point)
    refute Enum.any?([interfaces, managers], &Process.alive?/1)
  end

  test "a lookup queued ahead of runtime loss cannot strand graceful close", %{clock: clock} do
    address = {192, 0, 2, 41}
    control_point = start_control_point(clock, address)
    assert_receive {:opened, _interface, _socket, ^address}

    {id, :owner} = Runtime.identity(control_point)
    coordinator = ControlPoint.whereis(control_point)
    runtime = Runtime.whereis(id, :runtime)
    test = self()

    :ok = :sys.suspend(coordinator)

    on_exit(fn ->
      if Process.alive?(coordinator), do: :sys.resume(coordinator)
      if Process.alive?(control_point), do: :sys.resume(control_point)
    end)

    close_caller =
      spawn(fn ->
        send(test, {:close_result, self(), ControlPoint.close(control_point, 1_000)})
      end)

    await_owner_closing(control_point)

    assert Owner.track_subscription(
             control_point,
             coordinator,
             make_ref(),
             :roster,
             self()
           ) == {:error, :control_point_restarting}

    second_close_caller =
      spawn(fn ->
        send(test, {:close_result, self(), ControlPoint.close(control_point, 1_000)})
      end)

    await_owner_closing(control_point, 2)
    :ok = :sys.suspend(control_point)

    lookup_caller =
      spawn(fn ->
        send(test, {:lookup_result, self(), ControlPoint.roster(control_point)})
      end)

    await_queued_message(control_point)
    runtime_monitor = Process.monitor(runtime)
    :ok = :sys.resume(coordinator)
    assert_receive {:DOWN, ^runtime_monitor, :process, ^runtime, _reason}, 1_000
    :ok = :sys.resume(control_point)

    assert_receive {:lookup_result, ^lookup_caller, {:error, :control_point_restarting}},
                   1_000

    assert_receive {:close_result, ^close_caller, :ok}, 1_000
    assert_receive {:close_result, ^second_close_caller, :ok}, 1_000
    refute Process.alive?(control_point)
  end

  test "a dynamically started control point closes gracefully and leaves no child", %{
    clock: clock
  } do
    assert {:ok, control_point} =
             UPnP.start_control_point(
               interfaces: [{192, 0, 2, 18}],
               clock: {Manual, clock},
               udp_transport: {FakeTransport, self()}
             )

    on_exit(fn -> UPnP.stop_control_point(control_point) end)
    assert_receive {:opened, _interface, socket, {192, 0, 2, 18}}

    monitor = Process.monitor(control_point)
    assert :ok = ControlPoint.close(control_point)

    assert_receive {:DOWN, ^monitor, :process, ^control_point, :shutdown}
    assert_receive {:closed, ^socket}

    assert UPnP.stop_control_point(control_point) == {:error, :not_found}

    refute control_point in Enum.map(
             DynamicSupervisor.which_children(UPnP.ControlPointSupervisor),
             fn {_id, pid, _type, _modules} -> pid end
           )
  end

  test "closing a control point whose coordinator already died leaves nothing behind", %{
    clock: clock
  } do
    control_point = start_control_point(clock, {192, 0, 2, 19})
    assert_receive {:opened, interface, _socket, {192, 0, 2, 19}}

    {id, :owner} = Runtime.identity(control_point)
    coordinator = ControlPoint.whereis(control_point)
    interfaces = Runtime.whereis(id, :ssdp_interfaces)
    interface_monitor = Process.monitor(interface)
    runtime_monitor = Process.monitor(control_point)

    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^interface_monitor, :process, ^interface, _reason}

    assert :ok = ControlPoint.close(control_point)

    assert_receive {:DOWN, ^runtime_monitor, :process, ^control_point, _reason}
    refute Process.alive?(control_point)
    refute Process.alive?(interfaces)
    refute alive?(Runtime.whereis(id, :coordinator))
  end

  test "closing an already closed control point leaves no stray messages", %{clock: clock} do
    control_point = start_control_point(clock, {192, 0, 2, 22})
    assert_receive {:opened, _interface, socket, {192, 0, 2, 22}}

    assert :ok = ControlPoint.close(control_point)
    assert_receive {:closed, ^socket}

    assert :ok = ControlPoint.close(control_point)
    refute_receive {:DOWN, _monitor, :process, _pid, _reason}, 100
  end

  defp start_control_point(clock, address) do
    start_supervised!(
      {ControlPoint,
       interfaces: [address], clock: {Manual, clock}, udp_transport: {FakeTransport, self()}},
      id: {:control_point, address}
    )
  end

  defp crash_repeatedly(interface, _address, 0), do: interface

  defp crash_repeatedly(interface, address, remaining) do
    Process.exit(interface, :kill)
    assert_receive {:opened, restarted, _socket, ^address}
    crash_repeatedly(restarted, address, remaining - 1)
  end

  defp crash_coordinator_and_wait(control_point, address) do
    coordinator = ControlPoint.whereis(control_point)
    monitor = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^coordinator, :killed}
    assert_receive {:opened, _replacement, _socket, ^address}
    await_ready(control_point)
  end

  defp exhaust_runtime_generation(control_point, address) do
    Enum.each(1..5, fn _attempt ->
      crash_coordinator_and_wait(control_point, address)
    end)

    {id, :owner} = Runtime.identity(control_point)
    runtime = Runtime.whereis(id, :runtime)
    runtime_monitor = Process.monitor(runtime)
    coordinator = ControlPoint.whereis(control_point)
    monitor = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^coordinator, :killed}
    assert_receive {:DOWN, ^runtime_monitor, :process, ^runtime, :shutdown}
    assert ControlPoint.roster(control_point) == {:error, :control_point_restarting}
  end

  defp only_timer_delay(clock) do
    state = :sys.get_state(clock)
    assert map_size(state.timers) == 1
    [{_ref, {due_at, _sequence, _destination, _message}}] = Map.to_list(state.timers)
    due_at - state.now
  end

  defp await_ready(control_point, attempts \\ 1_000)

  defp await_ready(_control_point, 0), do: flunk("control point did not become ready")

  defp await_ready(control_point, attempts) do
    case :sys.get_state(control_point) do
      %{coordinator: coordinator} when is_pid(coordinator) ->
        if Process.alive?(coordinator) do
          :ok
        else
          :erlang.yield()
          await_ready(control_point, attempts - 1)
        end

      _state ->
        :erlang.yield()
        await_ready(control_point, attempts - 1)
    end
  end

  defp await_queued_message(process, attempts \\ 1_000)

  defp await_queued_message(_process, 0), do: flunk("process did not receive a message")

  defp await_queued_message(process, attempts) do
    case Process.info(process, :message_queue_len) do
      {:message_queue_len, count} when count > 0 ->
        :ok

      _other ->
        :erlang.yield()
        await_queued_message(process, attempts - 1)
    end
  end

  defp await_runtime_component(id, component, attempts \\ 1_000)

  defp await_runtime_component(_id, _component, 0),
    do: flunk("runtime component did not start")

  defp await_runtime_component(id, component, attempts) do
    case Runtime.whereis(id, component) do
      process when is_pid(process) ->
        process

      nil ->
        :erlang.yield()
        await_runtime_component(id, component, attempts - 1)
    end
  end

  defp await_owner_closing(control_point),
    do: await_owner_closing(control_point, 1, 1_000)

  defp await_owner_closing(control_point, count),
    do: await_owner_closing(control_point, count, 1_000)

  defp await_owner_closing(_control_point, _count, 0),
    do: flunk("control point did not begin closing")

  defp await_owner_closing(control_point, count, attempts) do
    case :sys.get_state(control_point) do
      %{closing: callers} when length(callers) >= count ->
        :ok

      _state ->
        :erlang.yield()
        await_owner_closing(control_point, count, attempts - 1)
    end
  end

  defp release_blocked_open(gate, attempt) do
    if Process.alive?(gate) do
      case Agent.get(gate, & &1.blocked) do
        pid when is_pid(pid) -> send(pid, {:continue, :open, attempt})
        nil -> :ok
      end
    end
  end

  defp children(supervisor) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
  end

  defp alive?(nil), do: false
  defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)
end
