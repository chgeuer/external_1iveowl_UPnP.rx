defmodule UPnP.ControlPoint.RuntimeTest do
  use ExUnit.Case, async: true

  alias UPnP.Clock.Manual
  alias UPnP.ControlPoint
  alias UPnP.ControlPoint.Runtime
  alias UPnP.SSDP.SearchTarget

  defmodule Named do
  end

  defmodule FakeTransport do
    @behaviour UPnP.SSDP.Transport

    @impl true
    def open(test, address, _options) do
      socket = make_ref()
      send(test, {:opened, self(), socket, address})
      {:ok, socket}
    end

    @impl true
    def activate(_test, _socket), do: :ok

    @impl true
    def send(test, socket, address, port, payload) do
      Kernel.send(test, {:sent, socket, address, port, IO.iodata_to_binary(payload)})
      :ok
    end

    @impl true
    def close(test, socket) do
      Kernel.send(test, {:closed, socket})
      :ok
    end
  end

  setup do
    {:ok, clock} = start_supervised(Manual)
    %{clock: clock}
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

    {first_id, :runtime} = Runtime.identity(first)
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
    assert ControlPoint.roster(control_point) == []
  end

  test "the runtime owns the coordinator, its interfaces, and its eventing", %{clock: clock} do
    control_point = start_control_point(clock, {192, 0, 2, 13})
    assert_receive {:opened, interface, _socket, {192, 0, 2, 13}}

    coordinator = ControlPoint.whereis(control_point)
    assert {:ok, manager} = ControlPoint.eventing_manager(control_point)
    assert {id, :runtime} = Runtime.identity(control_point)

    assert Runtime.whereis(id, :coordinator) == coordinator
    assert Runtime.identity(coordinator) == {id, :coordinator}
    assert ControlPoint.runtime(coordinator) == control_point
    assert ControlPoint.runtime(control_point) == control_point

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
    {id, :runtime} = Runtime.identity(control_point)
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

    runtime_monitor = Process.monitor(control_point)
    interface_monitor = Process.monitor(interface)
    manager_monitor = Process.monitor(manager)

    assert :ok = UPnP.stop_control_point(coordinator)

    assert_receive {:DOWN, ^runtime_monitor, :process, ^control_point, _reason}
    assert_receive {:DOWN, ^interface_monitor, :process, ^interface, _reason}
    assert_receive {:DOWN, ^manager_monitor, :process, ^manager, _reason}

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
    [{_id, control_point, :supervisor, _modules}] = Supervisor.which_children(owner)

    coordinator = ControlPoint.whereis(control_point)
    assert {:ok, manager} = ControlPoint.eventing_manager(control_point)
    {id, :runtime} = Runtime.identity(control_point)
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

    {id, :runtime} = Runtime.identity(control_point)
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

  defp children(supervisor) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
  end

  defp alive?(nil), do: false
  defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)
end
